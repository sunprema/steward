defmodule Steward.FakeDataPlane do
  @moduledoc """
  A scripted stand-in for a customer's data plane (doc 07 §10, E13): enough of
  the proxy, changeset engine, merge worker and adapter host, seen from the
  control plane's side of the `steward.plane.v1.Session` stream (doc 10 §5), to
  drive the control plane through every failure row of doc 13 §6 without Rust.

  It behaves as the real data plane would on the wire: it receives
  `Instruction`s, answers with `InstructionResult`s, `ChangesetReport`s and
  `MergeOutcome`s, sends `Heartbeat`s, and reacts to `HeartbeatReply`s by the
  doc 13 §6.8 table (`Steward.FakeDataPlane.Matrix`). It holds no row data and
  sends none (doc 13 invariant 9): reports are canned aggregates from
  `Steward.FakeDataPlane.Fixtures`.

  ## Transports

    * `:direct` (default): no network. Upstream messages are sent to the
      `:owner` process as `{:data_plane_message, data_plane_id, %DataPlaneMessage{}}`;
      the test (or the code under test, standing in for the Session host)
      delivers downstream messages with `deliver/2`. This is what E2 and the
      coordinator's tests use.
    * `{:grpc, "host:port"}` or `{:grpc, "host:port", opts}`: dials a real
      `Session.Connect` stream, as the engine does, and is driven by whatever
      Session server answers; E3's tests use it against the real host. It sends
      its id in `x-steward-data-plane-id` (the development identity); `opts`:
      `identity_header:` to claim another id, `cred:` a `GRPC.Credential` for mTLS.

  ## Scripting failures

  `script(dp, kind, behaviours)` queues behaviours for the next instructions of
  that kind; each instruction consumes one, and an empty queue means `:ok`.
  `{:always, behaviour}` never runs out. `{:delay, ms, behaviour}` runs the
  behaviour `ms` later. Behaviours common to every kind:

    * `:ok`: apply it and answer.
    * `:drop`: the instruction is lost; nothing applied, nothing sent.
    * `:lose_reply`: apply it, but the answer never arrives.
    * `{:error, code, message}`: not applied; `InstructionResult` with `ok: false`.

  Kind-specific behaviours, and the doc 13 §6 row each one reproduces:

  | Kind | Behaviour | Row |
  |---|---|---|
  | `:initialise_overlay` | `:lose_reply` | 6.1 f4, f5: orphan overlay, killed by heartbeat |
  | | `:drop`, `{:error, ..}` | 6.1 f2, f3: data plane unreachable / overlay store fails |
  | `:routing_upsert` | `:drop` | 6.1 f6: branch not routable until a heartbeat repairs it |
  | `:freeze_writes` | `:drop` | 6.3 f2: freeze times out; the heartbeat reply freezes it |
  | `:compute_changeset` | `{:compute_error, code, retryable}` | 6.3 f3, 6.2 f3 |
  | | `:crash` | 6.3 f3: changeset stays `computing` |
  | | `:lose_report` | 6.3 f4: reply lost; recompute overwrites |
  | | `{:report, overrides}` | verdict inputs: assertion results, conflicts |
  | `:merge` | `:stale_base`, `:compensation_failed`, `:snapshot_lost`, `{:adapter_error, code}` | 6.5 f4, f5, f6 |
  | | `:crash_before_checkpoint` | 6.5 f3: nothing durable on the data plane |
  | | `{:stall, rows, code}`, `:crash_after_checkpoint` | 6.5 f7: committed, apply stalled; `resume_merge/2` |
  | | `:lose_outcome` | 6.5 f8, f9: applied, outcome lost; the heartbeat reports complete |

  Heartbeat-driven rows (6.2 f5/f6, 6.7 f2/f3, 6.8) are exercised with
  `write/3`, `heartbeat/1` and `deliver/2` of a `HeartbeatReply`; see
  `Steward.FakeDataPlane.Matrix`.

  A merge's failure is reported as a `MergeOutcome` (status `failed`,
  `failure_reason`), after an `InstructionResult` with `ok: true` that only
  acknowledges the instruction. Doc 10 §5 lists `stale_base` and
  `compensation_failed` among `InstructionResult` error codes too; E6 owns which
  of the two the `Merge` reactor reads, and should settle it in doc 10.
  """
  use GenServer

  alias Steward.FakeDataPlane.{Fixtures, Matrix}
  alias Steward.Plane.V1

  @kinds [
    :initialise_overlay,
    :routing_upsert,
    :freeze_writes,
    :compute_changeset,
    :run_assertions,
    :merge,
    :close_overlay,
    :set_retention,
    :set_legal_hold,
    :register_target
  ]

  @default_merge_rows 12

  # --- API -------------------------------------------------------------------

  @doc """
  Options: `:data_plane_id`, `:owner` (default the caller), `:transport`
  (`:direct` | `{:grpc, address}` | `{:grpc, address, opts}`), `:version`, `:merge_rows`.
  """
  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :owner, self())
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def child_spec(opts),
    do: %{
      id: Keyword.get(opts, :data_plane_id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }

  def data_plane_id(dp), do: GenServer.call(dp, :data_plane_id)

  @doc "Queues behaviours for instructions of `kind` (see the moduledoc)."
  def script(dp, kind, behaviours) when kind in @kinds,
    do: GenServer.call(dp, {:script, kind, List.wrap(behaviours)})

  @doc """
  Delivers a downstream message (direct transport): a `ControlPlaneMessage`, or
  an `Instruction` / `HeartbeatReply` which is wrapped. Returns
  `{:error, :disconnected}` while disconnected.
  """
  def deliver(dp, message), do: GenServer.call(dp, {:deliver, message})

  @doc "Sends one `Heartbeat` per overlay (what the engine does every ~30 s). Returns how many."
  def heartbeat(dp), do: GenServer.call(dp, :heartbeat)

  @doc """
  Simulates an agent write through the proxy. `:ok`, or `{:error, reason}` with
  `:branch_not_routable | :branch_frozen | :base_snapshot_gone | :branch_merged |
  :branch_rejected | :branch_abandoned | :branch_closed | :held`.
  Options: `:rows` (1), `:bytes` (100), `overlay: :fail` (the overlay store write fails and nothing is
  acknowledged; doc 13 §6.2 f2), `evidence: :fail` (acknowledged, but the
  evidence gap counter increments; doc 13 §6.2 f4).
  """
  def write(dp, branch_id, opts \\ []), do: GenServer.call(dp, {:write, branch_id, opts})

  @doc "Marks the base snapshot gone (adapter `SNAPSHOT_LOST`); the next heartbeat carries it (doc 13 §6.2 f3)."
  def lose_base_snapshot(dp, branch_id), do: GenServer.call(dp, {:lose_base_snapshot, branch_id})

  @doc "Completes a stalled or crashed-after-checkpoint merge and sends its `MergeOutcome`."
  def resume_merge(dp, branch_id), do: GenServer.call(dp, {:resume_merge, branch_id})

  @doc "Moves a stalled merge's confirmed-row count forward without finishing it."
  def advance_merge(dp, branch_id, rows),
    do: GenServer.call(dp, {:advance_merge, branch_id, rows})

  @doc """
  Sends an arbitrary upstream message body (`{:audit_event, %DataPlaneAuditEvent{}}`,
  an oversized `{:changeset_report, _}`, ...), as the real engine might. For tests
  of how the control plane treats what it did not expect.
  """
  def inject(dp, {tag, body}), do: GenServer.call(dp, {:inject, tag, body})

  def overlay(dp, branch_id), do: GenServer.call(dp, {:overlay, branch_id})
  def overlays(dp), do: GenServer.call(dp, :overlays)

  @doc "Instructions received, oldest first."
  def received(dp), do: GenServer.call(dp, :received)

  @doc "Upstream messages sent (or dropped while disconnected, flagged), oldest first."
  def sent(dp), do: GenServer.call(dp, :sent)

  @doc "Reactions to heartbeat replies: `%{branch_id, believed, authoritative, new_believed, effects}`."
  def reactions(dp), do: GenServer.call(dp, :reactions)

  @doc "Overlays garbage-collected: `{branch_id, overlay_id}`."
  def gc_log(dp), do: GenServer.call(dp, :gc_log)

  @doc "The stream goes down. Upstream messages are dropped and instructions cannot be delivered."
  def disconnect(dp), do: GenServer.call(dp, :disconnect)

  @doc "Re-opens the stream (gRPC: dials again). Overlays survive, as they would a reconnect."
  def reconnect(dp), do: GenServer.call(dp, :reconnect)
  def connected?(dp), do: GenServer.call(dp, :connected?)

  # --- server ----------------------------------------------------------------

  defmodule Overlay do
    @moduledoc false
    defstruct [
      :branch_id,
      :overlay_id,
      :target_id,
      :base_snapshot_ref,
      :revert_of,
      :copied_from,
      :changeset_id,
      :merge,
      :compensation,
      :revert_outcome,
      :retention_ack,
      believed: :open,
      frozen: false,
      freeze_marker: false,
      rows: 0,
      bytes: 0,
      evidence_gap: 0,
      base_snapshot_gone: false,
      held: false,
      gc_scheduled: false,
      expecting_merge: false,
      terminal: nil
    ]
  end

  @impl true
  def init(opts) do
    state = %{
      id: Keyword.get(opts, :data_plane_id, "dp-#{System.unique_integer([:positive])}"),
      owner: Keyword.fetch!(opts, :owner),
      version: Keyword.get(opts, :version, "1.0.0"),
      merge_rows: Keyword.get(opts, :merge_rows, @default_merge_rows),
      transport: Keyword.get(opts, :transport, :direct),
      connected: false,
      stream: nil,
      channel: nil,
      reader: nil,
      scripts: %{},
      overlays: %{},
      routes: %{},
      received: [],
      sent: [],
      reactions: [],
      gc_log: [],
      alerts: [],
      legal_holds: %{}
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, s), do: {:noreply, open_stream(s)}

  @impl true
  def handle_call(:data_plane_id, _from, s), do: {:reply, s.id, s}
  def handle_call(:received, _from, s), do: {:reply, Enum.reverse(s.received), s}
  def handle_call(:sent, _from, s), do: {:reply, Enum.reverse(s.sent), s}
  def handle_call(:reactions, _from, s), do: {:reply, Enum.reverse(s.reactions), s}
  def handle_call(:gc_log, _from, s), do: {:reply, Enum.reverse(s.gc_log), s}
  def handle_call(:overlays, _from, s), do: {:reply, s.overlays, s}

  def handle_call({:overlay, branch_id}, _from, s),
    do: {:reply, Map.get(s.overlays, branch_id), s}

  def handle_call(:connected?, _from, s), do: {:reply, s.connected, s}

  def handle_call({:script, kind, behaviours}, _from, s) do
    {:reply, :ok,
     update_in(s.scripts, &Map.update(&1, kind, behaviours, fn q -> q ++ behaviours end))}
  end

  def handle_call({:deliver, _}, _from, %{connected: false} = s),
    do: {:reply, {:error, :disconnected}, s}

  def handle_call({:deliver, message}, _from, s) do
    {:reply, :ok, downstream(s, wrap(message))}
  end

  def handle_call(:heartbeat, _from, s) do
    s =
      Enum.reduce(s.overlays, s, fn {_branch_id, o}, acc ->
        emit(acc, {:heartbeat, build_heartbeat(o)})
      end)

    {:reply, map_size(s.overlays), s}
  end

  def handle_call({:write, branch_id, opts}, _from, s) do
    case check_write(s, branch_id, opts) do
      :ok ->
        o = s.overlays[branch_id]

        o = %{
          o
          | rows: o.rows + Keyword.get(opts, :rows, 1),
            bytes: o.bytes + Keyword.get(opts, :bytes, 100),
            evidence_gap: o.evidence_gap + if(opts[:evidence] == :fail, do: 1, else: 0)
        }

        {:reply, :ok, put_overlay(s, o)}

      {:error, _} = error ->
        {:reply, error, s}
    end
  end

  def handle_call({:lose_base_snapshot, branch_id}, _from, s) do
    {:reply, :ok, update_overlay(s, branch_id, &%{&1 | base_snapshot_gone: true})}
  end

  def handle_call({:advance_merge, branch_id, rows}, _from, s) do
    {:reply, :ok,
     update_overlay(s, branch_id, fn o -> %{o | merge: %{o.merge | rows_confirmed: rows}} end)}
  end

  def handle_call({:resume_merge, branch_id}, _from, s) do
    case s.overlays[branch_id] do
      %Overlay{merge: %{compensation_persisted: true} = m} = o ->
        m = %{
          m
          | rows_confirmed: m.rows_total,
            complete: true,
            last_error_code: nil,
            retry_after: nil
        }

        o = %{o | merge: m, believed: :done, compensation: compensation(m.merge_id, true)}
        {:reply, :ok, s |> put_overlay(o) |> emit({:merge_outcome, applied_outcome(m, o)})}

      _ ->
        {:reply, {:error, :no_committed_merge}, s}
    end
  end

  def handle_call({:inject, tag, body}, _from, s), do: {:reply, :ok, emit(s, {tag, body})}
  def handle_call(:disconnect, _from, s), do: {:reply, :ok, close_stream(s)}
  def handle_call(:reconnect, _from, s), do: {:reply, :ok, s |> close_stream() |> open_stream()}

  @impl true
  def handle_info({:control_plane_message, message}, s), do: {:noreply, downstream(s, message)}

  def handle_info({:run_delayed, instruction, behaviour}, s),
    do: {:noreply, run_instruction(s, instruction, behaviour)}

  def handle_info({:stream_closed, reader}, %{reader: reader} = s),
    do: {:noreply, %{s | connected: false, stream: nil, reader: nil}}

  def handle_info(_ignored, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    close_stream(s)
    :ok
  end

  # --- transport -------------------------------------------------------------

  defp open_stream(%{transport: :direct} = s), do: %{s | connected: true}

  defp open_stream(%{transport: {:grpc, address}} = s),
    do: open_stream(%{s | transport: {:grpc, address, []}})

  defp open_stream(%{transport: {:grpc, address, opts}} = s) do
    # Identity: the dev/test listener reads it from this header; with mTLS it is the
    # client certificate in `cred`. `identity_header:` lets a test claim another id.
    headers = [{"x-steward-data-plane-id", Keyword.get(opts, :identity_header, s.id)}]

    connect_opts =
      [adapter: GRPC.Client.Adapters.Mint, headers: headers] ++ Keyword.take(opts, [:cred])

    with {:ok, channel} <- GRPC.Stub.connect(address, connect_opts) do
      stream = V1.Session.Stub.connect(channel)
      parent = self()

      # The reader is its own process: `recv` blocks until the server answers.
      reader =
        spawn_link(fn ->
          with {:ok, replies} <- GRPC.Stub.recv(stream, timeout: :infinity) do
            Enum.each(replies, fn
              {:ok, message} -> send(parent, {:control_plane_message, message})
              _other -> :ok
            end)
          end

          send(parent, {:stream_closed, self()})
        end)

      %{s | channel: channel, stream: stream, reader: reader, connected: true}
    else
      _unreachable -> %{s | connected: false}
    end
  end

  defp close_stream(%{transport: {:grpc, _, _}, channel: channel} = s) when not is_nil(channel) do
    if s.reader, do: Process.unlink(s.reader)
    if s.stream, do: GRPC.Stub.end_stream(s.stream)
    GRPC.Stub.disconnect(channel)
    %{s | channel: nil, stream: nil, reader: nil, connected: false}
  end

  defp close_stream(%{transport: {:grpc, a}} = s),
    do: close_stream(%{s | transport: {:grpc, a, []}})

  defp close_stream(s), do: %{s | connected: false}

  defp emit(s, {tag, body}) do
    message = %V1.DataPlaneMessage{data_plane_id: s.id, version: s.version, body: {tag, body}}

    cond do
      not s.connected ->
        %{s | sent: [{:dropped, message} | s.sent]}

      s.transport == :direct ->
        send(s.owner, {:data_plane_message, s.id, message})
        %{s | sent: [message | s.sent]}

      true ->
        stream = GRPC.Stub.send_request(s.stream, message)
        %{s | stream: stream, sent: [message | s.sent]}
    end
  end

  defp wrap(%V1.ControlPlaneMessage{} = m), do: m
  defp wrap(%V1.Instruction{} = i), do: %V1.ControlPlaneMessage{body: {:instruction, i}}
  defp wrap(%V1.HeartbeatReply{} = r), do: %V1.ControlPlaneMessage{body: {:heartbeat_reply, r}}

  defp downstream(s, %V1.ControlPlaneMessage{body: {:instruction, instruction}}) do
    s = %{s | received: [instruction | s.received]}
    {behaviour, s} = pop_behaviour(s, kind(instruction))
    run_instruction(s, instruction, behaviour)
  end

  defp downstream(s, %V1.ControlPlaneMessage{body: {:heartbeat_reply, reply}}),
    do: react(s, reply)

  # --- scripts ---------------------------------------------------------------

  defp pop_behaviour(s, kind) do
    case Map.get(s.scripts, kind, []) do
      [{:always, b} = always | _] -> {b, put_in(s.scripts[kind], [always])}
      [b | rest] -> {b, put_in(s.scripts[kind], rest)}
      [] -> {:ok, s}
    end
  end

  defp kind(%V1.Instruction{body: {kind, _}}), do: kind

  # --- instructions ----------------------------------------------------------

  defp run_instruction(s, instruction, {:delay, ms, behaviour}) do
    Process.send_after(self(), {:run_delayed, instruction, behaviour}, ms)
    s
  end

  defp run_instruction(s, _instruction, :drop), do: s

  defp run_instruction(s, instruction, {:error, code, message}),
    do: reply(s, instruction, ok: false, error_code: code, safe_message: message)

  defp run_instruction(s, %V1.Instruction{body: {kind, msg}} = instruction, behaviour) do
    # `:lose_reply` applies the instruction exactly as `:ok` would; only the answer is lost.
    effective = if behaviour == :lose_reply, do: :ok, else: behaviour
    {s, replies} = apply_instruction(kind, msg, instruction, effective, s)
    if behaviour == :lose_reply, do: s, else: Enum.reduce(replies, s, &emit(&2, &1))
  end

  defp reply(s, instruction, opts) do
    body = Keyword.get(opts, :body)

    result = %V1.InstructionResult{
      instruction_id: instruction.instruction_id,
      ok: Keyword.get(opts, :ok, true),
      error_code: Keyword.get(opts, :error_code),
      safe_message: Keyword.get(opts, :safe_message),
      body: body,
      trace_context: instruction.trace_context
    }

    emit(s, {:instruction_result, result})
  end

  defp ack(instruction, body \\ nil),
    do:
      {:instruction_result,
       %V1.InstructionResult{
         instruction_id: instruction.instruction_id,
         ok: true,
         body: body,
         trace_context: instruction.trace_context
       }}

  # Returns {state, [upstream {tag, body}]}; the caller drops the list for :lose_reply.

  defp apply_instruction(:initialise_overlay, m, i, _b, s) do
    o =
      case s.overlays[m.branch_id] do
        nil ->
          %Overlay{
            branch_id: m.branch_id,
            overlay_id: Ecto.UUID.generate(),
            target_id: m.target_id,
            base_snapshot_ref: "snap-#{System.unique_integer([:positive])}",
            revert_of: m.revert_of_merge_id,
            copied_from: m.copy_overlay_from
          }

        existing ->
          # A re-sent instruction (same branch) is answered with the same overlay.
          existing
      end

    initialised = %V1.OverlayInitialised{
      overlay_id: o.overlay_id,
      base_snapshot_ref: o.base_snapshot_ref,
      fidelity: "TRUE_SNAPSHOT",
      opened_at: Fixtures.timestamp()
    }

    {put_overlay(s, o), [ack(i, {:overlay_initialised, initialised})]}
  end

  defp apply_instruction(:routing_upsert, m, i, _b, s) do
    route = %{
      overlay_id: m.overlay_id,
      state: Matrix.from_proto_authoritative(m.state),
      principal_id: m.principal_id
    }

    {put_in(s.routes[m.branch_id], route), [ack(i)]}
  end

  defp apply_instruction(:freeze_writes, m, i, _b, s) do
    s =
      update_overlay(s, m.branch_id, fn o ->
        if m.unfreeze,
          do: %{o | frozen: false, freeze_marker: false, believed: :open},
          else: %{o | frozen: true, freeze_marker: true, believed: :proposed}
      end)

    {s, [ack(i)]}
  end

  defp apply_instruction(:compute_changeset, m, i, b, s), do: compute(m, i, b, s, m.changeset_id)
  defp apply_instruction(:run_assertions, m, i, b, s), do: rerun(m, i, b, s)

  defp apply_instruction(:merge, m, i, b, s), do: merge(m, i, b, s)

  defp apply_instruction(:close_overlay, m, i, _b, s) do
    {gc(s, m.branch_id, :close_overlay), [ack(i)]}
  end

  defp apply_instruction(:set_retention, m, i, _b, s) do
    ack_for_merge(
      s,
      m.merge_id,
      %V1.RetentionAck{
        merge_id: m.merge_id,
        retention_until: m.retention_until,
        legal_hold: false
      },
      i
    )
  end

  defp apply_instruction(:set_legal_hold, %{merge_id: merge_id} = m, i, _b, s)
       when is_binary(merge_id) do
    ack_for_merge(s, merge_id, %V1.RetentionAck{merge_id: merge_id, legal_hold: m.legal_hold}, i)
  end

  defp apply_instruction(:set_legal_hold, m, i, _b, s) do
    {put_in(s.legal_holds[m.target_id], m.legal_hold), [ack(i)]}
  end

  defp apply_instruction(:register_target, m, i, _b, s) do
    {s, [ack(i, {:target_description, Fixtures.target_description(m.target_id)})]}
  end

  defp ack_for_merge(s, merge_id, retention_ack, instruction) do
    s =
      Enum.reduce(s.overlays, s, fn
        {_, %Overlay{merge: %{merge_id: ^merge_id}} = o}, acc ->
          prior = o.retention_ack

          merged = %{
            retention_ack
            | retention_until: retention_ack.retention_until || (prior && prior.retention_until),
              legal_hold: retention_ack.legal_hold || (prior && prior.legal_hold) || false
          }

          put_overlay(acc, %{o | retention_ack: merged})

        _, acc ->
          acc
      end)

    {s, [ack(instruction)]}
  end

  # --- compute ---------------------------------------------------------------

  # The engine died mid-compute: not even an acknowledgement.
  defp compute(_m, _i, :crash, s, _changeset_id), do: {s, []}

  defp compute(m, i, behaviour, s, changeset_id) do
    case s.overlays[m.branch_id] do
      nil ->
        {s, [error_result(i, "overlay_unreadable")]}

      %Overlay{} = o ->
        o = %{o | changeset_id: changeset_id}
        s = put_overlay(s, o)
        {s, [ack(i) | report_for(behaviour, o, changeset_id)]}
    end
  end

  defp rerun(m, i, behaviour, s) do
    case s.overlays |> Map.values() |> Enum.find(&(&1.changeset_id == m.source_changeset_id)) do
      nil -> {s, [error_result(i, "overlay_unreadable")]}
      o -> {s, [ack(i) | report_for(behaviour, o, m.changeset_id)]}
    end
  end

  defp report_for(behaviour, o, changeset_id) do
    base = fn overrides ->
      {:changeset_report,
       Fixtures.changeset_report(changeset_id, o.branch_id, o.overlay_id, overrides)}
    end

    cond do
      behaviour in [:crash, :lose_report] ->
        []

      o.base_snapshot_gone ->
        [base.(error: Fixtures.compute_error("base_snapshot_gone"))]

      not o.freeze_marker ->
        [base.(error: Fixtures.compute_error("freeze_marker_missing", true))]

      match?({:compute_error, _, _}, behaviour) ->
        [base.(error: Fixtures.compute_error(elem(behaviour, 1), elem(behaviour, 2)))]

      match?({:report, _}, behaviour) ->
        [base.(elem(behaviour, 1))]

      true ->
        [base.([])]
    end
  end

  defp error_result(instruction, code),
    do:
      {:instruction_result,
       %V1.InstructionResult{
         instruction_id: instruction.instruction_id,
         ok: false,
         error_code: code,
         safe_message: "synthetic #{code}",
         trace_context: instruction.trace_context
       }}

  # --- merge -----------------------------------------------------------------

  defp merge(m, i, behaviour, s) do
    case s.overlays[m.branch_id] do
      nil ->
        {s, [error_result(i, "overlay_unreadable")]}

      %Overlay{merge: %{merge_id: merge_id, compensation_persisted: true} = prior} = o
      when merge_id == m.merge_id ->
        # Re-sent after a lost reply (doc 13 §6.5 f6): the record exists, so continue.
        outcome = if prior.complete, do: [{:merge_outcome, applied_outcome(prior, o)}], else: []
        {s, [ack(i) | outcome]}

      %Overlay{} = o ->
        total = if o.rows > 0, do: o.rows, else: s.merge_rows

        pending = %{
          merge_id: m.merge_id,
          changeset_id: m.changeset_id,
          rows_total: total,
          rows_confirmed: 0,
          complete: false,
          compensation_persisted: false,
          last_error_code: nil,
          retry_after: nil
        }

        run_merge(behaviour, o, pending, i, s)
    end
  end

  defp run_merge(:ok, o, m, i, s), do: finish_merge(o, m, i, s, [])
  defp run_merge(:lose_outcome, o, m, i, s), do: finish_merge(o, m, i, s, [:lose_outcome])

  defp run_merge(:stale_base, o, m, i, s), do: fail_merge(o, m, i, s, "stale_base")

  defp run_merge(:compensation_failed, o, m, i, s),
    do: fail_merge(o, m, i, s, "compensation_failed")

  defp run_merge({:adapter_error, code}, o, m, i, s), do: fail_merge(o, m, i, s, code)

  defp run_merge(:snapshot_lost, o, m, i, s) do
    fail_merge(%{o | base_snapshot_gone: true}, m, i, s, "snapshot_lost")
  end

  defp run_merge(:crash_before_checkpoint, o, m, i, s) do
    {put_overlay(s, %{o | believed: :merging, merge: m}), [ack(i)]}
  end

  defp run_merge(:crash_after_checkpoint, o, m, i, s) do
    m = %{m | compensation_persisted: true}

    {put_overlay(s, %{
       o
       | believed: :merging,
         merge: m,
         compensation: compensation(m.merge_id, false)
     }), [ack(i)]}
  end

  defp run_merge({:stall, rows, code}, o, m, i, s) do
    m = %{
      m
      | compensation_persisted: true,
        rows_confirmed: rows,
        last_error_code: code,
        retry_after: Fixtures.timestamp(DateTime.add(DateTime.utc_now(), 60))
    }

    {put_overlay(s, %{
       o
       | believed: :merging,
         merge: m,
         compensation: compensation(m.merge_id, false)
     }), [ack(i)]}
  end

  defp finish_merge(o, m, i, s, flags) do
    m = %{m | compensation_persisted: true, rows_confirmed: m.rows_total, complete: true}
    o = %{o | believed: :done, merge: m, compensation: compensation(m.merge_id, true)}
    s = put_overlay(s, o)
    outcome = if :lose_outcome in flags, do: [], else: [{:merge_outcome, applied_outcome(m, o)}]
    {s, [ack(i) | outcome]}
  end

  defp fail_merge(o, m, i, s, reason) do
    outcome = %V1.MergeOutcome{
      merge_id: m.merge_id,
      status: "failed",
      failure_reason: reason,
      compensation_persisted: false,
      rows_applied: 0,
      duration_ms: 5
    }

    {put_overlay(s, %{o | believed: :proposed, merge: nil}), [ack(i), {:merge_outcome, outcome}]}
  end

  defp applied_outcome(m, _o) do
    %V1.MergeOutcome{
      merge_id: m.merge_id,
      status: "applied",
      compensation_persisted: true,
      compensation: compensation(m.merge_id, true),
      rows_applied: m.rows_total,
      duration_ms: 25
    }
  end

  defp compensation(merge_id, applied?) do
    %V1.CompensationStatus{
      merge_id: merge_id,
      status: :COMPLETE,
      merge_applied: applied?,
      header_hash: Base.encode16(Fixtures.digest("compensation-#{merge_id}"), case: :lower)
    }
  end

  # --- heartbeats ------------------------------------------------------------

  defp build_heartbeat(%Overlay{} = o) do
    %V1.Heartbeat{
      branch_id: o.branch_id,
      overlay_id: o.overlay_id,
      believed_state: Matrix.to_proto_believed(o.believed),
      overlay_size_bytes: o.bytes,
      overlay_rows: o.rows,
      merge_progress: o.merge && merge_progress(o.merge),
      evidence_gap: if(o.evidence_gap > 0, do: o.evidence_gap),
      compensation_status: o.compensation,
      revert_outcome: o.revert_outcome,
      retention_ack: o.retention_ack,
      freeze_acknowledged: o.frozen,
      base_snapshot_gone: o.base_snapshot_gone,
      sent_at: Fixtures.timestamp()
    }
  end

  defp merge_progress(m) do
    %V1.MergeProgress{
      merge_id: m.merge_id,
      rows_confirmed: m.rows_confirmed,
      rows_total: m.rows_total,
      complete: m.complete,
      compensation_persisted: m.compensation_persisted,
      last_error_code: m.last_error_code,
      retry_after: m.retry_after
    }
  end

  # --- reacting to heartbeat replies (doc 13 §6.8) ---------------------------

  defp react(s, %V1.HeartbeatReply{} = reply) do
    authoritative = Matrix.from_proto_authoritative(reply.authoritative_state)

    case s.overlays[reply.branch_id] do
      %Overlay{overlay_id: overlay_id, held: false} = o when overlay_id == reply.overlay_id ->
        {new_believed, effects} = Matrix.react(o.believed, authoritative)

        reaction = %{
          branch_id: o.branch_id,
          believed: o.believed,
          authoritative: authoritative,
          new_believed: new_believed,
          effects: effects
        }

        o = %{o | believed: new_believed}
        o = Enum.reduce(effects, o, &apply_effect(&1, &2, authoritative))

        o =
          if reply.freeze and not o.frozen, do: %{o | frozen: true, freeze_marker: true}, else: o

        o = apply_retention(o, reply)

        s = %{s | reactions: [reaction | s.reactions]}
        s = if authoritative == :open, do: repair_route(s, o), else: s

        s =
          if :alert in effects,
            do: %{s | alerts: [{o.branch_id, o.believed, authoritative} | s.alerts]},
            else: s

        if :gc_overlay in effects or :gc_when_safe in effects,
          do: gc(put_overlay(s, o), o.branch_id, {:heartbeat, authoritative}),
          else: put_overlay(s, o)

      %Overlay{overlay_id: overlay_id} when overlay_id != reply.overlay_id ->
        # Lookup is by both ids: a different overlay id is `unknown` to the control plane.
        %{
          s
          | reactions: [
              %{branch_id: reply.branch_id, ignored: :overlay_id_mismatch} | s.reactions
            ]
        }

      %Overlay{held: true} ->
        %{s | reactions: [%{branch_id: reply.branch_id, ignored: :held_for_human} | s.reactions]}

      nil ->
        %{s | reactions: [%{branch_id: reply.branch_id, ignored: :no_such_overlay} | s.reactions]}
    end
  end

  defp apply_effect(:freeze, o, _), do: %{o | frozen: true}
  defp apply_effect(:write_freeze_marker, o, _), do: %{o | freeze_marker: true}
  defp apply_effect(:unfreeze, o, _), do: %{o | frozen: false}
  defp apply_effect(:drop_freeze_marker, o, _), do: %{o | freeze_marker: false}
  defp apply_effect(:alert, o, _), do: %{o | held: true, frozen: true}
  defp apply_effect(:gc_after_retention, o, _), do: %{o | gc_scheduled: true}
  defp apply_effect(:expect_merge_instruction, o, _), do: %{o | expecting_merge: true}

  defp apply_effect(
         :stop_apply_if_before_checkpoint,
         %Overlay{merge: %{compensation_persisted: false}} = o,
         _
       ),
       do: %{o | merge: nil, believed: :proposed}

  defp apply_effect(:set_done, %Overlay{revert_of: revert_of} = o, authoritative)
       when not is_nil(revert_of) do
    outcome =
      %{merged: :RO_MERGED, rejected: :RO_REJECTED, abandoned: :RO_ABANDONED}[authoritative]

    if outcome,
      do: %{
        o
        | revert_outcome: %V1.RevertOutcome{revert_of_merge_id: revert_of, outcome: outcome}
      },
      else: o
  end

  defp apply_effect(:set_done, o, authoritative), do: %{o | terminal: authoritative}
  defp apply_effect(_effect, o, _), do: o

  defp apply_retention(o, %V1.HeartbeatReply{retention_until: nil, legal_hold: nil}), do: o

  defp apply_retention(%Overlay{merge: %{merge_id: merge_id}} = o, reply) do
    prior = o.retention_ack || %V1.RetentionAck{merge_id: merge_id}

    %{
      o
      | retention_ack: %{
          prior
          | retention_until: reply.retention_until || prior.retention_until,
            legal_hold: if(is_nil(reply.legal_hold), do: prior.legal_hold, else: reply.legal_hold)
        }
    }
  end

  defp apply_retention(o, _reply), do: o

  # §6.1 f6 / §6.7 f3: a heartbeat reply of `open` repairs a missing routing entry.
  defp repair_route(s, o) do
    if Map.has_key?(s.routes, o.branch_id),
      do: s,
      else:
        put_in(s.routes[o.branch_id], %{
          overlay_id: o.overlay_id,
          state: :open,
          principal_id: nil,
          repaired: true
        })
  end

  # --- writes ----------------------------------------------------------------

  defp check_write(s, branch_id, opts) do
    with %Overlay{} = o <- s.overlays[branch_id],
         %{state: route_state} <- s.routes[branch_id] || :unrouted do
      cond do
        route_state == :merged ->
          {:error, :branch_merged}

        route_state == :rejected ->
          {:error, :branch_rejected}

        route_state == :abandoned ->
          {:error, :branch_abandoned}

        route_state == :closed ->
          {:error, :branch_closed}

        o.terminal in [:merged, :rejected, :abandoned, :closed] ->
          {:error, :"branch_#{o.terminal}"}

        o.held ->
          {:error, :held}

        o.base_snapshot_gone ->
          {:error, :base_snapshot_gone}

        opts[:overlay] == :fail ->
          {:error, :overlay_store_unavailable}

        o.frozen ->
          {:error, :branch_frozen}

        true ->
          :ok
      end
    else
      _ -> {:error, :branch_not_routable}
    end
  end

  # --- overlay bookkeeping ---------------------------------------------------

  defp put_overlay(s, %Overlay{} = o), do: put_in(s.overlays[o.branch_id], o)

  defp update_overlay(s, branch_id, fun) do
    case s.overlays[branch_id] do
      nil -> s
      o -> put_overlay(s, fun.(o))
    end
  end

  defp gc(s, branch_id, reason) do
    case s.overlays[branch_id] do
      nil ->
        s

      o ->
        %{
          s
          | overlays: Map.delete(s.overlays, branch_id),
            gc_log: [{branch_id, o.overlay_id, reason} | s.gc_log]
        }
    end
  end
end

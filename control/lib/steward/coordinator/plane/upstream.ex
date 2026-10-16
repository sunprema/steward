defmodule Steward.Coordinator.Plane.Upstream do
  @moduledoc """
  What the control plane does with each message a data plane sends (doc 10 §5).
  `handle/2` is pure in the sense that matters for testing: it takes a decoded
  `DataPlaneMessage` and returns the messages to send back; it opens no socket.

    * `Heartbeat`: rate-limited per identity, then `Steward.Coordinator.Heartbeat`
      and a `HeartbeatReply`. Over budget the heartbeat is dropped, not answered
      (doc 07 §5.3: "dropping a heartbeat is safe").
    * `InstructionResult`: to the waiting caller via the session.
    * `ChangesetReport`, `MergeOutcome`: to `Steward.Coordinator.Plane.Handlers`.
    * `DataPlaneAuditEvent`: written to `audit_log` (doc 09 §8, metadata only).

  A message whose `data_plane_id` is not the stream's identity is refused
  (`{:error, :identity_mismatch}`); the caller closes the stream (doc 10 §5).
  """
  require Logger

  alias Steward.Coordinator.{Heartbeat, Plane}
  alias Steward.Coordinator.Plane.{Handlers, Limiter, Wire}
  alias Steward.Core.Audit.AuditLog
  alias Steward.Core.Authz.System
  alias Steward.Plane.V1

  defstruct [:org_id, :data_plane_id, :limiter, :capacity_at, :capacity_ms]

  @doc """
  The state for one stream. `:non_terminal` is the number of non-terminal
  branches on this data plane, which sizes the heartbeat bucket; the caller
  refreshes it with `retune/3`.
  """
  def new(org_id, data_plane_id, opts \\ []) do
    now = now()
    rate = Limiter.rate_for(Keyword.get(opts, :non_terminal, 0))

    %__MODULE__{
      org_id: org_id,
      data_plane_id: data_plane_id,
      limiter: Limiter.new(Keyword.get(opts, :rate, rate), now),
      capacity_at: now,
      capacity_ms: Keyword.get(opts, :capacity_ms, 30_000)
    }
  end

  @doc "Re-sizes the heartbeat bucket for a new branch count."
  def retune(%__MODULE__{} = s, non_terminal, now \\ now()),
    do: %{
      s
      | limiter: Limiter.retune(s.limiter, Limiter.rate_for(non_terminal), now),
        capacity_at: now
    }

  @doc "True when it is time to refresh the branch count."
  def stale_capacity?(%__MODULE__{capacity_at: at, capacity_ms: ms}), do: now() - at >= ms

  @doc "`{state, [ControlPlaneMessage]}` or `{:error, :identity_mismatch}`."
  def handle(
        %__MODULE__{data_plane_id: id} = s,
        %V1.DataPlaneMessage{data_plane_id: claimed} = message
      ) do
    if claimed != id do
      {:error, :identity_mismatch}
    else
      dispatch(s, message.body)
    end
  end

  defp dispatch(s, {:heartbeat, %V1.Heartbeat{} = hb}) do
    case Limiter.take(s.limiter, now()) do
      {:limited, limiter} ->
        :telemetry.execute([:steward, :plane, :heartbeat_rate_limited], %{count: 1}, %{
          data_plane_id: s.data_plane_id
        })

        {%{s | limiter: limiter}, []}

      {:ok, limiter} ->
        s = %{s | limiter: limiter}
        {s, heartbeat(s, hb)}
    end
  end

  defp dispatch(s, {:instruction_result, %V1.InstructionResult{} = result}) do
    Plane.deliver_result(s.data_plane_id, result)
    {s, []}
  end

  defp dispatch(s, {:changeset_report, report}) do
    log(Handlers.impl().changeset_report(s.org_id, s.data_plane_id, report), :changeset_report)
    {s, []}
  end

  defp dispatch(s, {:merge_outcome, outcome}) do
    log(Handlers.impl().merge_outcome(s.org_id, s.data_plane_id, outcome), :merge_outcome)
    {s, []}
  end

  defp dispatch(s, {:audit_event, %V1.DataPlaneAuditEvent{} = event}) do
    log(record_audit(s, event), :audit_event)
    {s, []}
  end

  defp dispatch(s, nil), do: {s, []}

  defp heartbeat(s, %V1.Heartbeat{} = hb) do
    with {:ok, map} <- Wire.heartbeat(hb),
         {:ok, reply} <- Heartbeat.handle(s.org_id, map) do
      [Wire.control_message(Wire.heartbeat_reply(hb, reply))]
    else
      # Nothing destructive: no reply means the data plane keeps its state and tries again.
      {:error, reason} ->
        Logger.warning("heartbeat for #{hb.branch_id} not answered: #{inspect(reason)}")
        []
    end
  end

  # --- audit events (doc 09 §8) ------------------------------------------------

  # What a data plane may report (doc 12 §2.5): grant use against row deltas and
  # compensation. The rest of the `audit_log` vocabulary is written by the control
  # plane itself, so a data plane naming one of those is refused. The proto
  # comment on `DataPlaneAuditEvent.action` says `compensation.export`; doc 12's
  # vocabulary, which wins, is `compensation.exported`.
  @data_plane_actions ~w(row_delta.read compensation.opened compensation.read compensation.exported compensation.verified)

  defp record_audit(_s, %V1.DataPlaneAuditEvent{action: action})
       when action not in @data_plane_actions,
       do: {:error, {:unknown_audit_action, action}}

  defp record_audit(s, %V1.DataPlaneAuditEvent{} = event) do
    {object_type, object_id} =
      if event.changeset_id in [nil, ""],
        do: {"merge", event.merge_id},
        else: {"changeset", event.changeset_id}

    AuditLog
    |> Ash.Changeset.for_create(
      :create,
      %{
        principal_id: uuid_or_nil(event.principal_id),
        action: event.action,
        object_type: object_type,
        object_id: object_id,
        grant_id: uuid_or_nil(event.grant_jti),
        data_plane_id: s.data_plane_id,
        details: %{},
        occurred_at: timestamp(event.at)
      },
      tenant: s.org_id,
      actor: System.new(:session, s.org_id)
    )
    |> Ash.create()
    |> case do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp uuid_or_nil(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp timestamp(nil), do: DateTime.utc_now()

  defp timestamp(%{seconds: seconds, nanos: nanos}),
    do: DateTime.from_unix!(seconds * 1_000_000 + div(nanos, 1000), :microsecond)

  defp log(:ok, _kind), do: :ok

  defp log({:error, reason}, kind) do
    Logger.warning("#{kind} from the data plane not accepted: #{inspect(reason)}")
    :telemetry.execute([:steward, :plane, :message_rejected], %{count: 1}, %{kind: kind})
  end

  defp now, do: Elixir.System.monotonic_time(:millisecond)
end

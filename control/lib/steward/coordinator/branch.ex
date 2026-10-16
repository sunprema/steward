defmodule Steward.Coordinator.Branch do
  @moduledoc """
  One process per non-terminal branch (doc 07 §4). It serialises the branch's
  lifecycle transitions and answers its heartbeats, and holds nothing that is
  not in the `Branch` row: state is a cache, rebuilt from Postgres on start and
  refreshed from every action's result (doc 13 invariant 1).

  ## What it does

    * `transition/5` runs a lifecycle Ash action on the branch as
      `Steward.Core.Authz.System` `:coordinator`. Every transition carries
      `optimistic_lock(:lock_version)`, so a stale cache, or another node
      writing, fails as `{:error, :stale_transition}` (doc 07 §5) with the cache
      refreshed; nothing is half-written. After a terminal transition commits
      the process stops itself (doc 07 §6, "GenServer leak").
    * `heartbeat/3` decides the reply by `HeartbeatMatrix` from what the data
      plane believes and the cached state, and runs the cell's actions through
      `Steward.Coordinator.HeartbeatActions`. It touches no database, so a
      Postgres outage still gets an answer, marked `stale: true` once a refresh
      has failed (doc 07 §6: the data plane keeps the overlay and does nothing
      destructive).
    * A self-tick every 30 s ±20 % (doc 03 principle 4) re-reads the row and
      stops the process if the branch is terminal or gone. The retries it will
      carry (pending merge instruction, routing adds) arrive with E4/E6.

  `last_heartbeat_at` is recorded in process state only; flushing it in batches
  (`HeartbeatFlusher`) is E3.
  """
  use GenServer, restart: :transient

  require Logger

  alias Steward.Coordinator
  alias Steward.Coordinator.{HeartbeatActions, HeartbeatMatrix}
  alias Steward.Core.Authz.System
  alias Steward.Core.Branches.Branch, as: BranchRecord

  @terminal [:merged, :rejected, :abandoned, :closed]
  @tick_ms 30_000
  @call_timeout 1_000

  # --- API -------------------------------------------------------------------

  @doc """
  Makes sure a process exists for the branch and returns its pid.

  `{:error, :not_found}` if there is no such branch in the org, `{:error,
  :terminal}` if it is terminal (terminal branches have no process). Idempotent:
  concurrent callers get the same pid.
  """
  def ensure_started(org_id, branch_id, opts \\ []) do
    case Coordinator.whereis(branch_id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start(org_id, branch_id, opts)
    end
  end

  # A `record:` hint saves the sweeps one read per branch, but the child spec
  # keeps its start arguments for restarts, so the hint is only trusted for a few
  # seconds; a process restarted later re-reads the row (doc 07 §5.1).
  defp hint_ms,
    do:
      Application.get_env(:steward, Steward.Coordinator, [])
      |> Keyword.get(:record_hint_ms, 5_000)

  defp start(org_id, branch_id, opts) do
    opts =
      case Keyword.pop(opts, :record) do
        {nil, opts} ->
          opts

        {record, opts} ->
          opts
          |> Keyword.put(:record, record)
          |> Keyword.put(
            :record_valid_until,
            Elixir.System.monotonic_time(:millisecond) + hint_ms()
          )
      end

    spec = %{
      id: {__MODULE__, branch_id},
      start: {__MODULE__, :start_link, [{org_id, branch_id, opts}]},
      restart: :transient
    }

    supervisor = {:via, PartitionSupervisor, {Coordinator.supervisors(), branch_id}}

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
      :ignore -> {:error, :terminal}
    end
  end

  def start_link({org_id, branch_id, opts}) do
    name = {:via, Registry, {Coordinator.registry(), branch_id, org_id}}
    GenServer.start_link(__MODULE__, {org_id, branch_id, opts}, name: name)
  end

  @doc """
  Runs `action` on the branch through its process and returns the updated
  record. `{:error, :stale_transition | :invalid_transition | :not_found |
  :terminal | :unavailable | Ash.Error.t()}`.
  """
  def transition(org_id, branch_id, action, params \\ %{}, opts \\ []) do
    with {:ok, pid} <- ensure_started(org_id, branch_id) do
      GenServer.call(pid, {:transition, action, params, opts}, Keyword.get(opts, :timeout, 5_000))
    end
  catch
    :exit, {:noproc, _} -> {:error, :terminal}
    :exit, {:normal, _} -> {:error, :terminal}
  end

  @doc """
  Answers one heartbeat. `heartbeat` is `%{overlay_id: binary, believed:
  atom, merge_progress: nil | %{merge_id, rows_confirmed, rows_total, complete,
  compensation_persisted}}`. Returns the reply map (`authoritative`, `freeze`,
  `lease_renewed`, `stale`).
  """
  def heartbeat(pid, heartbeat) when is_pid(pid) do
    GenServer.call(pid, {:heartbeat, heartbeat}, @call_timeout)
  end

  @doc "The cached record. For tests and operators; not a read path."
  def get(pid), do: GenServer.call(pid, :get)

  @doc "Re-reads the row (after something else changed it)."
  def refresh(pid), do: GenServer.cast(pid, :refresh)

  @doc "When the last heartbeat for this branch was handled, or nil."
  def last_heartbeat_at(pid), do: GenServer.call(pid, :last_heartbeat_at)

  # --- server ----------------------------------------------------------------

  @impl true
  def init({org_id, branch_id, opts}) do
    state = %{
      org_id: org_id,
      branch_id: branch_id,
      record: trusted_hint(opts),
      last_progress: nil,
      last_heartbeat_at: nil,
      stale: false,
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms)
    }

    # The record is (re)read here, as doc 07 §5.1 says: a process started
    # before its row is visible cannot exist. A terminal branch gets no process.
    with {:ok, record} <- load(state) do
      state = %{state | record: record}

      if record.state in @terminal,
        do: :ignore,
        else: {:ok, schedule_tick(state)}
    else
      {:error, :not_found} -> {:stop, :not_found}
      {:error, _unavailable} -> {:stop, :unavailable}
    end
  end

  defp trusted_hint(opts) do
    if Keyword.get(opts, :record_valid_until, 0) > Elixir.System.monotonic_time(:millisecond),
      do: Keyword.get(opts, :record)
  end

  defp load(%{record: nil} = state), do: read(state)
  defp load(%{record: record}), do: {:ok, record}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state.record, state}
  def handle_call(:last_heartbeat_at, _from, state), do: {:reply, state.last_heartbeat_at, state}

  def handle_call({:heartbeat, hb}, _from, state) do
    {reply, state} = reconcile(hb, state)
    {:reply, reply, state}
  end

  def handle_call({:transition, action, params, opts}, _from, state) do
    case run_transition(state, action, params, opts) do
      {:ok, record} ->
        state = %{state | record: record, stale: false}

        if record.state in @terminal,
          do: {:stop, :normal, {:ok, record}, state},
          else: {:reply, {:ok, record}, state}

      {:error, :stale_transition} ->
        {:reply, {:error, :stale_transition}, refresh_cache(state)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_cast(:refresh, state), do: after_refresh(refresh_cache(state))

  @impl true
  def handle_info(:tick, state) do
    state = refresh_cache(state)

    if state.record.state in @terminal,
      do: {:stop, :normal, state},
      else: {:noreply, schedule_tick(state)}
  end

  def handle_info(_ignored, state), do: {:noreply, state}

  defp after_refresh(%{record: %{state: s}} = state) when s in @terminal,
    do: {:stop, :normal, state}

  defp after_refresh(state), do: {:noreply, state}

  # --- heartbeat -------------------------------------------------------------

  defp reconcile(%{overlay_id: overlay_id} = hb, state) do
    record = state.record

    # Lookup is by both ids: a different overlay id is `unknown`, which is how a
    # retry's orphan dies (doc 13 §6.8).
    authoritative =
      if to_string(record.overlay_id) == to_string(overlay_id), do: record.state, else: :unknown

    progress = progress(hb[:merge_progress], state.last_progress)
    {reply, actions} = HeartbeatMatrix.decide(hb.believed, authoritative, progress)

    ctx = %{
      org_id: state.org_id,
      branch: record,
      believed: hb.believed,
      authoritative: authoritative,
      merge_progress: hb[:merge_progress]
    }

    results =
      Map.new(actions, fn action -> {action, HeartbeatActions.impl().execute(action, ctx)} end)

    reply =
      reply
      |> Map.put(:lease_renewed, Map.get(results, :renew_lease) == :ok)
      |> Map.put(:stale, state.stale)
      |> Map.put(:actions, Map.new(results))

    {reply,
     %{
       state
       | last_heartbeat_at: DateTime.utc_now(),
         last_progress: if(hb[:merge_progress], do: hb.merge_progress, else: state.last_progress)
     }}
  end

  defp progress(nil, _last), do: nil

  defp progress(now, last) do
    %{
      advancing: is_nil(last) or now.rows_confirmed > last.rows_confirmed,
      complete: now.complete,
      compensation_persisted: now.compensation_persisted
    }
  end

  # --- transitions -----------------------------------------------------------

  defp run_transition(state, action, params, opts) do
    record = state.record
    actor = Keyword.get(opts, :actor, System.new(:coordinator, state.org_id))

    record
    |> Ash.Changeset.for_update(action, params, actor: actor, tenant: state.org_id)
    |> Ash.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, error} -> {:error, classify(error)}
    end
  rescue
    error in [Ash.Error.Invalid, Ash.Error.Forbidden, Ash.Error.Unknown] ->
      {:error, classify(error)}
  end

  defp classify(%{errors: errors} = error) when is_list(errors) do
    cond do
      Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1)) ->
        :stale_transition

      Enum.any?(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1)) ->
        :invalid_transition

      Enum.any?(errors, &match?(%Ash.Error.Unknown.UnknownError{}, &1)) ->
        :unavailable

      true ->
        error
    end
  end

  defp classify(error), do: error

  # --- cache -----------------------------------------------------------------

  defp read(state) do
    BranchRecord
    |> Ash.get(state.branch_id,
      tenant: state.org_id,
      actor: System.new(:coordinator, state.org_id)
    )
    |> case do
      {:ok, record} -> {:ok, record}
      {:error, %{errors: [%Ash.Error.Query.NotFound{} | _]}} -> {:error, :not_found}
      {:error, error} -> {:error, classify(error)}
    end
  end

  # A failed refresh keeps the cache and marks it stale: the next heartbeat
  # reply says so (doc 07 §6).
  defp refresh_cache(state) do
    case read(state) do
      {:ok, record} -> %{state | record: record, stale: false}
      {:error, :not_found} -> %{state | record: %{state.record | state: :closed}}
      {:error, _} -> %{state | stale: true}
    end
  end

  defp schedule_tick(state) do
    jitter = round(state.tick_ms * (0.8 + :rand.uniform() * 0.4))
    Process.send_after(self(), :tick, jitter)
    state
  end
end

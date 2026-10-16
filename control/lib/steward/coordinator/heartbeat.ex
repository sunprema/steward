defmodule Steward.Coordinator.Heartbeat do
  @moduledoc """
  The dispatch half of doc 07 §5.3, for the gRPC `Session` service (E3) to call:
  find the branch's process, or answer from the row.

    * A process exists: `GenServer.call` it (1 s timeout).
    * No process, branch non-terminal and the overlay id matches: start one,
      then call it. A heartbeat for a live branch whose process is missing
      (crash, node restart) rebuilds it.
    * No process, branch terminal, unknown, or the overlay id differs: answer
      straight from Postgres through the same matrix, starting nothing.
      Terminal branches must have no process (doc 07 §6), and starting one
      would recreate the leak.

  `org_id` comes from the data-plane identity (mTLS SAN → the org that enrolled
  it, doc 15 §4.2); a branch in another org is `unknown`.
  """
  alias Steward.Coordinator
  alias Steward.Coordinator.{Branch, HeartbeatActions, HeartbeatMatrix}
  alias Steward.Core.Authz.System
  alias Steward.Core.Branches.Branch, as: BranchRecord

  @terminal [:merged, :rejected, :abandoned, :closed]

  def handle(org_id, %{branch_id: branch_id} = heartbeat) do
    case Coordinator.whereis(branch_id) do
      pid when is_pid(pid) -> call(pid, org_id, heartbeat)
      nil -> dispatch(org_id, heartbeat)
    end
  end

  defp dispatch(org_id, %{branch_id: branch_id, overlay_id: overlay_id} = heartbeat) do
    case fetch(org_id, branch_id) do
      {:ok, %{overlay_id: ^overlay_id, state: state} = record} when state not in @terminal ->
        case Branch.ensure_started(org_id, branch_id, record: record) do
          {:ok, pid} -> call(pid, org_id, heartbeat)
          {:error, _} -> from_row(org_id, record, heartbeat)
        end

      {:ok, record} ->
        from_row(org_id, record, heartbeat)

      {:error, :not_found} ->
        from_row(org_id, nil, heartbeat)

      {:error, _unavailable} ->
        # Postgres is down and nothing is cached: say nothing destructive.
        {:error, :unavailable}
    end
  end

  defp call(pid, _org_id, heartbeat) do
    {:ok, Branch.heartbeat(pid, heartbeat)}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # Terminal, unknown, or a different overlay: the matrix, no process, no actions
  # beyond `:alert` (which has no process-held state to need).
  defp from_row(org_id, record, heartbeat) do
    authoritative =
      cond do
        is_nil(record) -> :unknown
        to_string(record.overlay_id) != to_string(heartbeat.overlay_id) -> :unknown
        true -> record.state
      end

    {reply, actions} = HeartbeatMatrix.decide(heartbeat.believed, authoritative, nil)

    results =
      if record,
        do:
          Map.new(actions, fn action ->
            {action,
             HeartbeatActions.impl().execute(action, %{
               org_id: org_id,
               branch: record,
               believed: heartbeat.believed,
               authoritative: authoritative,
               merge_progress: heartbeat[:merge_progress]
             })}
          end),
        else: %{}

    {:ok, reply |> Map.merge(%{lease_renewed: false, stale: false, actions: results})}
  end

  defp fetch(org_id, branch_id) do
    case Ash.get(BranchRecord, branch_id, tenant: org_id, actor: System.new(:coordinator, org_id)) do
      {:ok, record} -> {:ok, record}
      {:error, %{errors: [%Ash.Error.Query.NotFound{} | _]}} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end
end

defmodule Steward.Core.Branches.Changes.LeaveProposed do
  @moduledoc """
  What leaving `proposed` or `open` for another state does to the branch's
  satellites, in the same transaction as the transition (doc 13 §2.1, §6.7):

    * `supersede: reason` — the live changeset is superseded with `reason`
      (`:withdrawn`, `:compute_failed`, or the branch's own terminal reason via
      `supersede: :branch_reason`), so a branch that is not `proposed` or
      `merging` never holds a live changeset it can no longer use (doc 13 §3).
    * `queue: true` — its review queue entry is removed ("Queue entry removed").

  A `rejected` branch keeps its last changeset live "for audit" (doc 13 §3), so
  `reject` uses `queue: true` alone.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Steward.Core.Authz.System
  alias Steward.Core.Branches.{Changeset, QueueEntry}

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, branch ->
      actor = System.new(:coordinator, branch.org_id)

      with :ok <- maybe_supersede(opts[:supersede], branch, actor),
           :ok <- maybe_clear_queue(opts[:queue], branch, actor) do
        {:ok, branch}
      end
    end)
  end

  defp maybe_supersede(nil, _branch, _actor), do: :ok

  defp maybe_supersede(reason, branch, actor) do
    reason = if reason == :branch_reason, do: branch.reason, else: reason

    Changeset
    |> Ash.Query.filter(branch_id == ^branch.id and state != :superseded)
    |> Ash.read!(tenant: branch.org_id, actor: actor)
    |> each(fn live ->
      live
      |> Ash.Changeset.for_update(:supersede, %{superseded_reason: reason},
        tenant: branch.org_id,
        actor: actor
      )
      |> Ash.update()
    end)
  end

  defp maybe_clear_queue(true, branch, actor) do
    QueueEntry
    |> Ash.Query.filter(branch_id == ^branch.id)
    |> Ash.read!(tenant: branch.org_id, actor: actor)
    |> each(&Ash.destroy(&1, tenant: branch.org_id, actor: actor))
  end

  defp maybe_clear_queue(_, _branch, _actor), do: :ok

  defp each(records, fun) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case fun.(record) do
        {:ok, _} -> {:cont, :ok}
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end

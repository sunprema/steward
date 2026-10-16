defmodule Steward.Core.Branches.Changes.EnsureQueueEntry do
  @moduledoc """
  Makes sure an evaluated `hold` changeset has its review queue entry (doc 13 §6.3
  f7, doc 07 §5.5). The queue entry is a read model derived from the changeset,
  its verdict and its branch, so rebuilding a missing one is always safe;
  `queue_entries` is unique on `changeset_id`, so doing it twice is the same as once.
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Steward.Core.Authz.System
  alias Steward.Core.Branches.{Branch, QueueEntry, Verdict}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      record = changeset.data
      actor = System.new(:coordinator, record.org_id)

      with {:ok, branch} <-
             Ash.get(Branch, record.branch_id, tenant: record.org_id, actor: actor),
           {:ok, %Verdict{} = verdict} <- verdict(record, actor),
           {:ok, _entry} <- upsert(record, branch, verdict, actor) do
        changeset
      else
        {:ok, nil} -> Ash.Changeset.add_error(changeset, field: :id, message: "has no verdict")
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  defp verdict(record, actor) do
    Verdict
    |> Ash.Query.filter(changeset_id == ^record.id)
    |> Ash.read_one(tenant: record.org_id, actor: actor)
  end

  defp upsert(record, branch, verdict, actor) do
    QueueEntry
    |> Ash.Changeset.for_create(
      :upsert,
      %{
        target_id: branch.target_id,
        changeset_id: record.id,
        branch_id: branch.id,
        principal_id: branch.principal_id,
        hold_reasons: [%{reason: verdict.reason}]
      },
      tenant: record.org_id,
      actor: actor
    )
    |> Ash.create()
  end
end

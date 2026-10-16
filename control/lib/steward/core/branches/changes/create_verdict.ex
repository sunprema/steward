defmodule Steward.Core.Branches.Changes.CreateVerdict do
  @moduledoc """
  Part of `Changeset.record_verdict`, the `Propose` checkpoint (doc 07 §5.2,
  doc 13 §6.3 step 9): the changeset becomes `evaluated` and its `Verdict` row is
  written in the same transaction, so a changeset is never evaluated without
  one (doc 13 invariant 4). The verdict comes in as the `verdict` argument:

      %{outcome:, reason:, policy_outcome:, policy_version_ids:, control_plane_ms:, data_plane_ms:}

  A changeset already holding a verdict is a conflict, not a second verdict:
  re-evaluation creates a new changeset (doc 13 §3).
  """
  use Ash.Resource.Change

  alias Steward.Core.Authz.System
  alias Steward.Core.Branches.Verdict

  @impl true
  def change(changeset, _opts, _context) do
    verdict = Ash.Changeset.get_argument(changeset, :verdict)

    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      Verdict
      |> Ash.Changeset.for_create(
        :create,
        Map.put(verdict, :changeset_id, record.id),
        tenant: record.org_id,
        actor: System.new(:coordinator, record.org_id)
      )
      |> Ash.create()
      |> case do
        {:ok, created} -> {:ok, Ash.Resource.put_metadata(record, :verdict, created)}
        {:error, error} -> {:error, error}
      end
    end)
  end
end

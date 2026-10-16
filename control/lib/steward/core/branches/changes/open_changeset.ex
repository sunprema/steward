defmodule Steward.Core.Branches.Changes.OpenChangeset do
  @moduledoc """
  Part of `Branch.propose` (doc 13 §3, §6.3 step 1): in the same transaction as
  the `open → proposed` transition, supersede the branch's live changeset (if any,
  with reason `new_changeset`) and create the next one in `computing`. "In every
  case the previous changeset **must** be marked `superseded` in the same Postgres
  transaction that creates the new one."

  The old one is superseded *first*: `one_live_per_branch` is a unique index on
  non-superseded changesets, so two cannot coexist even for an instant. That
  means the old row's `superseded_by_id` stays nil; the `new_changeset` reason and
  `sequence` order are what link them.

  The created changeset travels back in the record's metadata (`:changeset`).
  """
  use Ash.Resource.Change

  require Ash.Query

  alias Steward.Core.Authz.System
  alias Steward.Core.Branches.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    trigger = Ash.Changeset.get_argument(changeset, :trigger) || "propose"
    rationale = Ash.Changeset.get_argument(changeset, :rationale)

    Ash.Changeset.after_action(changeset, fn _changeset, branch ->
      actor = System.new(:coordinator, branch.org_id)

      with {:ok, existing} <- list(branch, actor),
           :ok <- supersede_live(existing, branch, actor),
           {:ok, new} <- create(branch, actor, next_sequence(existing), trigger, rationale) do
        {:ok, Ash.Resource.put_metadata(branch, :changeset, new)}
      end
    end)
  end

  defp list(branch, actor) do
    Changeset
    |> Ash.Query.filter(branch_id == ^branch.id)
    |> Ash.read(tenant: branch.org_id, actor: actor)
  end

  defp next_sequence([]), do: 1

  defp next_sequence(existing),
    do: existing |> Enum.map(& &1.sequence) |> Enum.max() |> Kernel.+(1)

  defp supersede_live(existing, branch, actor) do
    existing
    |> Enum.reject(&(&1.state == :superseded))
    |> Enum.reduce_while(:ok, fn old, :ok ->
      old
      |> Ash.Changeset.for_update(:supersede, %{superseded_reason: :new_changeset},
        tenant: branch.org_id,
        actor: actor
      )
      |> Ash.update()
      |> case do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp create(branch, actor, sequence, trigger, rationale) do
    Changeset
    |> Ash.Changeset.for_create(
      :create,
      %{
        branch_id: branch.id,
        target_id: branch.target_id,
        sequence: sequence,
        trigger: trigger,
        rationale: rationale
      },
      tenant: branch.org_id,
      actor: actor
    )
    |> Ash.create()
  end
end

defmodule Steward.Core.Audit.AppendEvent do
  @moduledoc """
  Appends one `Steward.Core.Audit.Event` row inside the same transaction as
  the action that triggers it, via an `after_action` hook — never a
  notifier, which runs after commit and would break doc 13 invariant 1's
  atomicity (doc 07 §5.0, doc 12 §0). Attached to every mutating action on a
  "Truth" resource (doc 07 §4):

      change {Steward.Core.Audit.AppendEvent,
              type: "branch.created",
              aggregate_type: "branch",
              payload: &__MODULE__.created_payload/2}

  `payload` receives `(changeset, record)` — `changeset.data` is the record
  before the action, for events that carry a `from_state` — and must return
  a map of bounded scalars/ID arrays only (doc 12 §6.1), never a row value.
  `aggregate_id`, if given, extracts the aggregate's id from the record
  (default `& &1.id`); `PolicyVersion`'s events use it to report the parent
  `Policy`'s id instead of its own.
  """
  use Ash.Resource.Change

  @impl Ash.Resource.Change
  def change(changeset, opts, %{actor: actor}) do
    type = Keyword.fetch!(opts, :type)
    aggregate_type = Keyword.fetch!(opts, :aggregate_type)
    payload_fn = Keyword.get(opts, :payload, fn _changeset, _record -> %{} end)
    aggregate_id_fn = Keyword.get(opts, :aggregate_id, & &1.id)

    Ash.Changeset.after_action(changeset, fn changeset, record ->
      event_attrs = %{
        type: type,
        aggregate_type: aggregate_type,
        aggregate_id: aggregate_id_fn.(record),
        actor_principal_id: actor_principal_id(actor),
        payload: payload_fn.(changeset, record),
        occurred_at: DateTime.utc_now()
      }

      Steward.Core.Audit.Event
      |> Ash.Changeset.for_create(:create, event_attrs,
        tenant: record.org_id,
        authorize?: false
      )
      |> Ash.create()
      |> case do
        {:ok, _event} -> {:ok, record}
        {:error, error} -> {:error, error}
      end
    end)
  end

  # An API key's own id is not a principal; attribute the event to the
  # principal the actor acts as (nil for system actors).
  defp actor_principal_id(actor), do: Steward.Core.Authz.principal_id(actor)
end

defmodule Steward.Core.Branches.QueueEntry do
  @moduledoc """
  Doc 12 §2.3 `queue_entries` — read model derived from events; rebuildable
  from `changesets` + `verdicts` + `branches` (doc 07 §5.5). No
  `AppendEvent` change (doc 12 §0).
  """
  alias Steward.Core.Authz.Checks.{ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Branches,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "queue_entries"
    repo Steward.Repo

    custom_statements do
      statement :validate_boundary_json_fn do
        up Steward.Core.Audit.BoundaryJson.create_function_sql()
        down Steward.Core.Audit.BoundaryJson.drop_function_sql()
      end

      statement :validate_boundary_json_hold_reasons do
        up Steward.Core.Audit.BoundaryJson.create_trigger_sql("queue_entries", "hold_reasons")
        down Steward.Core.Audit.BoundaryJson.drop_trigger_sql("queue_entries", "hold_reasons")
      end
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :hold_reasons, {:array, :map}, allow_nil?: false, default: []
    attribute :entered_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0
    attribute :priority, :integer, allow_nil?: false, default: 0
  end

  relationships do
    belongs_to :target, Steward.Core.Targets.Target do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :changeset, Steward.Core.Branches.Changeset do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :branch, Steward.Core.Branches.Branch do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :principal, Steward.Core.Targets.Principal do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_changeset, [:changeset_id]
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: "review:read"}
    end

    policy action([:upsert]) do
      authorize_if {SystemActor, roles: [:coordinator, :jobs]}
    end

    policy action([:destroy]) do
      authorize_if {SystemActor, roles: [:coordinator, :jobs]}
    end
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true
      upsert? true
      upsert_identity :unique_changeset
      accept [:target_id, :changeset_id, :branch_id, :principal_id, :hold_reasons]
    end
  end
end

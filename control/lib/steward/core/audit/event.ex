defmodule Steward.Core.Audit.Event do
  @moduledoc """
  Doc 12 §6 `events` — the domain-event backbone, appended by
  `Steward.Core.Audit.AppendEvent` inside the triggering action's
  transaction. Append-only; partitioned by `occurred_at` (hand-written
  migration fragment, doc 12 §0, since Ash has no partitioning concept).
  """
  use Ash.Resource,
    domain: Steward.Core.Audit,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "events"
    repo Steward.Repo

    # Doc 12 §2.4: rejects any boundary jsonb column containing a row-data
    # key at any depth — defence in depth behind the Ash-level check.
    # `CREATE OR REPLACE` is idempotent, so every resource with a boundary
    # jsonb column declares its own copy of the function before its own
    # trigger (doc 12 §0): cross-resource statement ordering isn't
    # reliable, but every resource ordering itself is.
    custom_statements do
      statement :validate_boundary_json_fn do
        up Steward.Core.Audit.BoundaryJson.create_function_sql()
        down Steward.Core.Audit.BoundaryJson.drop_function_sql()
      end

      statement :validate_boundary_json_payload do
        up Steward.Core.Audit.BoundaryJson.create_trigger_sql("events", "payload")
        down Steward.Core.Audit.BoundaryJson.drop_trigger_sql("events", "payload")
      end

      # Doc 12 §2.5: append-only, enforced two ways.
      statement :raise_immutable_fn do
        up Steward.Core.Audit.AppendOnly.raise_immutable_function_sql()
        down Steward.Core.Audit.AppendOnly.drop_raise_immutable_function_sql()
      end

      statement :events_immutable_trigger do
        up Steward.Core.Audit.AppendOnly.create_trigger_sql("events")
        down Steward.Core.Audit.AppendOnly.drop_trigger_sql("events")
      end

      statement :events_grants do
        up Steward.Core.Audit.AppendOnly.revoke_sql("events")
        down Steward.Core.Audit.AppendOnly.grant_sql("events")
      end
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    integer_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false
    attribute :type, :string, allow_nil?: false
    attribute :aggregate_type, :string, allow_nil?: false
    attribute :aggregate_id, :uuid, allow_nil?: false
    attribute :actor_principal_id, :uuid, allow_nil?: true
    attribute :payload, :map, allow_nil?: false, default: %{}
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :type,
        :aggregate_type,
        :aggregate_id,
        :actor_principal_id,
        :payload,
        :occurred_at
      ]
    end
  end
end

defmodule Steward.Core.Audit.AuditLog do
  @moduledoc """
  Doc 12 §2.3 `audit_log` — access records with no consumer (`grant.issued`,
  row-delta reads, compensation access, API-key/membership/target-settings/
  legal-hold/policy-activation changes). Append-only.
  """
  alias Steward.Core.Authz.Checks.{ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Audit,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "audit_log"
    repo Steward.Repo

    custom_statements do
      statement :validate_boundary_json_fn do
        up Steward.Core.Audit.BoundaryJson.create_function_sql()
        down Steward.Core.Audit.BoundaryJson.drop_function_sql()
      end

      statement :validate_boundary_json_details do
        up Steward.Core.Audit.BoundaryJson.create_trigger_sql("audit_log", "details")
        down Steward.Core.Audit.BoundaryJson.drop_trigger_sql("audit_log", "details")
      end

      statement :raise_immutable_fn do
        up Steward.Core.Audit.AppendOnly.raise_immutable_function_sql()
        down Steward.Core.Audit.AppendOnly.drop_raise_immutable_function_sql()
      end

      statement :audit_log_immutable_trigger do
        up Steward.Core.Audit.AppendOnly.create_trigger_sql("audit_log")
        down Steward.Core.Audit.AppendOnly.drop_trigger_sql("audit_log")
      end

      statement :audit_log_grants do
        up Steward.Core.Audit.AppendOnly.revoke_sql("audit_log")
        down Steward.Core.Audit.AppendOnly.grant_sql("audit_log")
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

    attribute :principal_id, :uuid, allow_nil?: true
    # Fixed M0 vocabulary (doc 12 §2.5): grant.issued, row_delta.read,
    # compensation.{opened,read,exported,verified}, api_key.{created,revoked},
    # membership.{granted,revoked}, target_settings.changed,
    # legal_hold.{set,cleared}, policy.{activated,retired}. Enforced by a
    # hand-written migration CHECK, not here (:string has no `one_of`).
    attribute :action, :string, allow_nil?: false

    attribute :object_type, :string, allow_nil?: false
    attribute :object_id, :uuid, allow_nil?: false
    attribute :grant_id, :uuid, allow_nil?: true
    attribute :data_plane_id, :string, allow_nil?: true
    attribute :details, :map, allow_nil?: false, default: %{}
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: "audit:read", target: :org}
    end

    policy action([:create]) do
      authorize_if {SystemActor, roles: [:session, :api, :coordinator]}
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :principal_id,
        :action,
        :object_type,
        :object_id,
        :grant_id,
        :data_plane_id,
        :details,
        :occurred_at
      ]
    end
  end
end

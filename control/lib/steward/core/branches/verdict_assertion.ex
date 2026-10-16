defmodule Steward.Core.Branches.VerdictAssertion do
  @moduledoc """
  Doc 12 §2.2 `verdict_assertions`. Doc 12's primary key is the composite
  `(verdict_id, policy_assertion_id)`; modelled as a surrogate `uuid_v7` id
  plus a tenant-scoped unique identity on those two columns, same pattern
  as `Steward.Core.Targets.TargetMembership`. Append-only.
  """
  use Ash.Resource,
    domain: Steward.Core.Branches,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "verdict_assertions"
    repo Steward.Repo

    check_constraints do
      check_constraint :error_code, "error_has_code",
        check: "(status = 'error') = (error_code IS NOT NULL)"

      # Never sample_keys: the ref is a locator, keys stay in the data plane.
      check_constraint :sample_ref, "sample_ref_shape",
        check: "sample_ref IS NULL OR sample_ref ~ '^[0-9a-f-]{36}/[a-z0-9-]+/[a-z0-9-]+$'"
    end

    custom_statements do
      statement :raise_immutable_fn do
        up Steward.Core.Audit.AppendOnly.raise_immutable_function_sql()
        down Steward.Core.Audit.AppendOnly.drop_raise_immutable_function_sql()
      end

      statement :verdict_assertions_immutable_trigger do
        up Steward.Core.Audit.AppendOnly.create_trigger_sql("verdict_assertions")
        down Steward.Core.Audit.AppendOnly.drop_trigger_sql("verdict_assertions")
      end

      statement :verdict_assertions_grants do
        up Steward.Core.Audit.AppendOnly.revoke_sql("verdict_assertions")
        down Steward.Core.Audit.AppendOnly.grant_sql("verdict_assertions")
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

    attribute :status, Steward.Core.Types.AssertionStatus, allow_nil?: false

    attribute :count, :integer,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0, max: 1_000_000]

    attribute :count_capped, :boolean, allow_nil?: false, default: false
    attribute :denominator, :integer, allow_nil?: true
    attribute :sample_ref, :string, allow_nil?: true
    attribute :error_code, :string, allow_nil?: true
    attribute :duration_ms, :integer, allow_nil?: false

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :verdict, Steward.Core.Branches.Verdict do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :policy_assertion, Steward.Core.Policies.PolicyAssertion do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_verdict_assertion, [:verdict_id, :policy_assertion_id]
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :verdict_id,
        :policy_assertion_id,
        :status,
        :count,
        :count_capped,
        :denominator,
        :sample_ref,
        :error_code,
        :duration_ms
      ]
    end
  end
end

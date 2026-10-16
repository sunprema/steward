defmodule Steward.Core.Policies.PolicyAssertion do
  @moduledoc "Doc 12 §2.2 `policy_assertions` — one row per assertion so fire rates are per assertion (doc 06 §9)."
  use Ash.Resource,
    domain: Steward.Core.Policies,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "policy_assertions"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :assertion_id, :string,
      allow_nil?: false,
      constraints: [match: ~r/^[a-z0-9][a-z0-9-]{0,63}$/]

    attribute :description, :string, allow_nil?: true
    attribute :sql, :string, allow_nil?: false, constraints: [max_length: 65_536]
    attribute :expect, :map, allow_nil?: false
    attribute :position, :integer, allow_nil?: false

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :policy_version, Steward.Core.Policies.PolicyVersion do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_assertion_id, [:policy_version_id, :assertion_id]
    identity :unique_position, [:policy_version_id, :position]
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:policy_version_id, :assertion_id, :description, :sql, :expect, :position]
    end
  end
end

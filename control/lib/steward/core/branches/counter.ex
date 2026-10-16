defmodule Steward.Core.Branches.Counter do
  @moduledoc "Doc 12 §2.3 `counters` — totals derived from `CounterDelta` by `CounterDrain` (doc 07 §5.8)."
  alias Steward.Core.Authz.Checks.{SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Branches,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "counters"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :key, :string, allow_nil?: false
    attribute :scope, :map, allow_nil?: false, default: %{}
    attribute :value, :integer, allow_nil?: false, default: 0

    update_timestamp :updated_at
  end

  identities do
    identity :unique_key_scope, [:key, :scope]
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: [:api, :jobs, :coordinator]}
    end

    policy action([:upsert]) do
      authorize_if {SystemActor, roles: [:jobs, :coordinator]}
    end
  end

  actions do
    defaults [:read]

    create :upsert do
      primary? true
      upsert? true
      upsert_identity :unique_key_scope
      upsert_fields [:value]
      accept [:key, :scope, :value]
    end
  end
end

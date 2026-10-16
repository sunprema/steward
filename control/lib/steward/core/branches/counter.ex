defmodule Steward.Core.Branches.Counter do
  @moduledoc "Doc 12 §2.3 `counters` — totals derived from `CounterDelta` by `CounterDrain` (doc 07 §5.8)."
  use Ash.Resource,
    domain: Steward.Core.Branches,
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

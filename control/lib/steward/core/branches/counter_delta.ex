defmodule Steward.Core.Branches.CounterDelta do
  @moduledoc "Doc 12 §2.3 `counter_deltas`; drained into `Counter` by `CounterDrain` (doc 07 §5.8, E8, out of scope here)."
  use Ash.Resource,
    domain: Steward.Core.Branches,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "counter_deltas"
    repo Steward.Repo

    # Doc 12 §2.5: delete-only by `CounterDrain` — keeps DELETE, loses UPDATE.
    custom_statements do
      statement :counter_deltas_grants do
        up Steward.Core.Audit.AppendOnly.revoke_delete_only_sql("counter_deltas")
        down Steward.Core.Audit.AppendOnly.grant_delete_only_sql("counter_deltas")
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

    attribute :key, :string, allow_nil?: false
    attribute :scope, :map, allow_nil?: false, default: %{}
    attribute :delta, :integer, allow_nil?: false

    create_timestamp :inserted_at
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:key, :scope, :delta]
    end
  end
end

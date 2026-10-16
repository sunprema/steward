defmodule Steward.Core.Targets.ImpactQuery do
  @moduledoc "Doc 12 §2.3 `impact_queries`; metrics are named `<name>.<column>` (doc 05 §5.3)."
  use Ash.Resource,
    domain: Steward.Core.Targets,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "impact_queries"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :name, :string, allow_nil?: false
    attribute :sql, :string, allow_nil?: false
    attribute :timeout_s, :integer, allow_nil?: false, default: 30
    attribute :enabled, :boolean, allow_nil?: false, default: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :target, Steward.Core.Targets.Target do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :created_by_principal, Steward.Core.Targets.Principal do
      source_attribute :created_by
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_name, [:target_id, :name]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:target_id, :name, :sql, :timeout_s, :enabled, :created_by]
    end

    update :update do
      primary? true
      accept [:sql, :timeout_s, :enabled]
    end
  end
end

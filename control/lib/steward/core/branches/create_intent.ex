defmodule Steward.Core.Branches.CreateIntent do
  @moduledoc """
  Doc 12 §2.3 `create_intents` (doc 13 §6.1). `id` is the candidate branch
  ID; `branch_id` is only set once `Branch.create` (the checkpoint) commits.
  """
  use Ash.Resource,
    domain: Steward.Core.Branches,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "create_intents"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :idempotency_key, :string, allow_nil?: false
    attribute :state, Steward.Core.Types.CreateIntentState, allow_nil?: false, default: :pending

    update_timestamp :updated_at
  end

  relationships do
    belongs_to :target, Steward.Core.Targets.Target do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :principal, Steward.Core.Targets.Principal do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :branch, Steward.Core.Branches.Branch do
      attribute_writable? true
    end
  end

  identities do
    identity :unique_idempotency_key, [:principal_id, :idempotency_key]
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:target_id, :principal_id, :idempotency_key]
    end

    update :commit do
      accept [:branch_id]
      change set_attribute(:state, :committed)
    end

    update :fail do
      accept []
      change set_attribute(:state, :failed)
    end

    update :supersede do
      accept []
      change set_attribute(:state, :superseded)
    end
  end
end

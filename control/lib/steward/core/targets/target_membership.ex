defmodule Steward.Core.Targets.TargetMembership do
  @moduledoc """
  Doc 12 §2.3 `target_memberships`. Doc 12's primary key is the composite
  `(org_id, target_id, principal_id, capability)`; modelled here as a
  surrogate `uuid_v7` id plus a tenant-scoped unique identity on the same
  three columns, which is equivalent for uniqueness and is how every other
  Ash-backed join resource in this schema is keyed. The "agent may not hold
  `policy_admin`" trigger (doc 06 §8) is a hand-written migration fragment.
  """
  use Ash.Resource,
    domain: Steward.Core.Targets,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "target_memberships"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false
    attribute :capability, Steward.Core.Types.Capability, allow_nil?: false

    create_timestamp :inserted_at
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

    belongs_to :granted_by_principal, Steward.Core.Targets.Principal do
      source_attribute :granted_by
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_grant, [:target_id, :principal_id, :capability]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:target_id, :principal_id, :capability, :granted_by]
    end
  end
end

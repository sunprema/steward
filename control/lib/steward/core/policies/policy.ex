defmodule Steward.Core.Policies.Policy do
  @moduledoc "Doc 12 §2.2 `policies` — one row per policy identity; versions carry the content."
  use Ash.Resource,
    domain: Steward.Core.Policies,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "policies"
    repo Steward.Repo

    references do
      reference :target, match_tenant?: true
      reference :created_by_principal, match_tenant?: true
    end

    check_constraints do
      check_constraint :slug, "slug_format", check: "slug ~ '^[a-z0-9][a-z0-9-]{0,63}$'"
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :slug, :string,
      allow_nil?: false,
      constraints: [match: ~r/^[a-z0-9][a-z0-9-]{0,63}$/]

    attribute :archived_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :target, Steward.Core.Targets.Target do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :active_version, Steward.Core.Policies.PolicyVersion do
      attribute_writable? true
    end

    belongs_to :derived_from, __MODULE__ do
      attribute_writable? true
    end

    belongs_to :created_by_principal, Steward.Core.Targets.Principal do
      source_attribute :created_by
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_slug, [:target_id, :slug]
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:target_id, :slug, :derived_from_id, :created_by]
    end

    update :set_active_version do
      accept [:active_version_id]
    end

    update :archive do
      accept []
      change set_attribute(:archived_at, &DateTime.utc_now/0)
    end
  end
end

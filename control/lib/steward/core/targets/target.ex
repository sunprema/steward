defmodule Steward.Core.Targets.Target do
  @moduledoc """
  Doc 12 §2.3 `targets`. `merging_merge_id`/`last_merge_id` are plain `uuid`
  attributes, not Ash relationships: `Steward.Core.Branches.Merge` lives in a
  domain that depends on `Targets`, so a relationship pointing back here
  would be a boundary cycle. The lease (`merging_merge_id`,
  `lease_expires_at`) is columns here per doc 07 §5.4's decision, not a
  separate `merge_leases` table; the conditional-`UPDATE` lease actions
  themselves (doc 07 §5.4) are the `Merge` reactor's first step (E6, out of
  scope here) — this resource only needs to hold and expose the columns.
  """
  use Ash.Resource,
    domain: Steward.Core.Targets,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "targets"
    repo Steward.Repo

    check_constraints do
      check_constraint :merging_merge_id, "lease_pair",
        check: "(merging_merge_id IS NULL) = (lease_expires_at IS NULL)"
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :slug, :string, allow_nil?: false
    attribute :name, :string, allow_nil?: false
    attribute :kind, Steward.Core.Types.TargetKind, allow_nil?: false
    attribute :credential_ref, :string, allow_nil?: false, sensitive?: true
    attribute :data_plane_id, :string, allow_nil?: true
    attribute :merging_merge_id, :uuid, allow_nil?: true
    attribute :lease_expires_at, :utc_datetime_usec, allow_nil?: true
    attribute :last_merge_id, :uuid, allow_nil?: true
    attribute :archived_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :created_by_principal, Steward.Core.Targets.Principal do
      source_attribute :created_by
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
    # Doc 12 §1: parents carry UNIQUE (org_id, id), so a child's composite
    # (org_id, foo_id) FK (`match_tenant?: true`) has something to reference.
    identity :unique_org_id, [:id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:slug, :name, :kind, :credential_ref, :data_plane_id, :created_by]
    end

    update :update do
      primary? true

      accept [
        :name,
        :credential_ref,
        :data_plane_id,
        :merging_merge_id,
        :lease_expires_at,
        :last_merge_id,
        :archived_at
      ]
    end
  end
end

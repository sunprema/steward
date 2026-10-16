defmodule Steward.Core.Targets.Adapter do
  @moduledoc "Doc 12 §2.3 `adapters` — one per target (doc 02); the catalog snapshot, never rows."
  alias Steward.Core.Authz.Checks.{ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "adapters"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :kind, Steward.Core.Types.TargetKind, allow_nil?: false
    attribute :version, :string, allow_nil?: false
    attribute :capabilities, :map, allow_nil?: false, default: %{}
    attribute :catalog, :map, allow_nil?: false, default: %{}
    attribute :catalog_digest, :binary, allow_nil?: true
    attribute :described_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :target, Steward.Core.Targets.Target do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_target, [:target_id]
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: :any}
    end

    policy action([:create, :update]) do
      authorize_if {SystemActor, roles: [:session, :coordinator]}
    end

    policy action([:destroy]) do
      authorize_if {SystemActor, roles: [:jobs]}
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:target_id, :kind, :version, :capabilities, :catalog, :catalog_digest]
    end

    update :update do
      primary? true
      accept [:version, :capabilities, :catalog, :catalog_digest, :described_at]
    end
  end
end

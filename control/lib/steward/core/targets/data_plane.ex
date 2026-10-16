defmodule Steward.Core.Targets.DataPlane do
  @moduledoc "Doc 12 §2.3 `data_planes` — enrolment (doc 14 §6); `targets.data_plane_id` references it."
  alias Steward.Core.Authz.Checks.{Scope, ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "data_planes"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :region, :string, allow_nil?: false
    attribute :chart_version, :string, allow_nil?: false
    attribute :cert_serial, :string, allow_nil?: false
    attribute :enrolled_at, :utc_datetime_usec, allow_nil?: false
    attribute :last_session_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_cert_serial, [:cert_serial], all_tenants?: true
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: "target:admin", target: :org}
    end

    policy action([:create]) do
      authorize_if {Scope, scope: "target:admin", target: :any}
    end

    policy action([:update]) do
      authorize_if {SystemActor, roles: [:session]}
      authorize_if {Scope, scope: "target:admin", target: :any}
    end

    policy action([:destroy]) do
      authorize_if {SystemActor, roles: [:jobs]}
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:region, :chart_version, :cert_serial, :enrolled_at]
    end

    update :update do
      primary? true
      accept [:chart_version, :last_session_at]
    end
  end
end

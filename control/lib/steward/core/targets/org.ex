defmodule Steward.Core.Targets.Org do
  @moduledoc """
  Doc 12 §2.3 `orgs` — the tenant root; the one resource in the schema with
  no `org_id` column (doc 12 §10's three-table allow-list).
  """
  alias Steward.Core.Authz.Checks.{ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "orgs"
    repo Steward.Repo
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :slug, :string, allow_nil?: false
    attribute :name, :string, allow_nil?: false

    attribute :audit_retention, :duration,
      allow_nil?: false,
      default: &__MODULE__.default_audit_retention/0

    attribute :archived_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_slug, [:slug]
  end

  policies do
    # Orgs are provisioned out of band (doc 07 §8); no API actor creates or changes one.
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any, tenantless: true}
      authorize_if {ScopedRead, target: :own_org, tenantless: true}
    end

    policy action([:create, :update, :destroy]) do
      authorize_if {SystemActor, roles: [:jobs], tenantless: true}
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:slug, :name, :audit_retention]
    end

    update :update do
      primary? true
      accept [:name, :audit_retention, :archived_at]
    end
  end

  def default_audit_retention, do: Duration.new!(year: 2)
end

defmodule Steward.Core.Targets.Principal do
  @moduledoc """
  Doc 12 §2.3 `principals`. The policy-scope form `agent:pricing-bot` is
  `kind <> ":" <> slug` (doc 06 §4.2).
  """
  alias Steward.Core.Authz.Checks.{OrgAdmin, ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "principals"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :kind, Steward.Core.Types.PrincipalKind, allow_nil?: false
    attribute :slug, :string, allow_nil?: false
    attribute :display_name, :string, allow_nil?: false
    attribute :org_admin, :boolean, allow_nil?: false, default: false
    attribute :email, :string, allow_nil?: true
    attribute :sso_subject, :string, allow_nil?: true
    attribute :disabled_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    # Load before using a human principal as an actor: membership capabilities
    # are what `Steward.Core.Authz` resolves to scopes (doc 15 §3.1). An unloaded
    # list grants nothing.
    has_many :memberships, Steward.Core.Targets.TargetMembership do
      destination_attribute :principal_id
    end
  end

  identities do
    identity :unique_kind_slug, [:kind, :slug]
    identity :unique_org_id, [:id]
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if OrgAdmin
      authorize_if {ScopedRead, or_principal: :id}
    end

    policy action([:create, :update, :destroy]) do
      authorize_if OrgAdmin
      authorize_if {SystemActor, roles: [:api, :jobs]}
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:kind, :slug, :display_name, :org_admin, :email, :sso_subject]
    end

    update :update do
      primary? true
      accept [:display_name, :org_admin, :email, :sso_subject, :disabled_at]
    end
  end

  def scope_id(%{kind: kind, slug: slug}), do: "#{kind}:#{slug}"
end

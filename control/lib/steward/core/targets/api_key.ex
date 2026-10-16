defmodule Steward.Core.Targets.ApiKey do
  @moduledoc """
  Doc 12 §2.3 `api_keys`. The secret itself is never stored (doc 07 §8);
  only `secret_sha256`. Pushed to data planes via `RoutingUpsert` (doc 04 §8).
  """
  alias Steward.Core.Authz.Checks.{OrgAdmin, ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "api_keys"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :prefix, :string, allow_nil?: false
    attribute :secret_sha256, :binary, allow_nil?: false, sensitive?: true
    attribute :scopes, {:array, :string}, allow_nil?: false, default: []
    attribute :target_ids, {:array, :uuid}, allow_nil?: false, default: []
    attribute :last_used_at, :utc_datetime_usec, allow_nil?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: true
    attribute :revoked_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :principal, Steward.Core.Targets.Principal do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_prefix, [:prefix], all_tenants?: true
  end

  policies do
    # Authenticating a request by key prefix runs before any actor exists and is done by
    # the authenticator with authorization off (doc 10 §3.1); everything else comes through here.
    policy action_type(:read) do
      authorize_if {SystemActor, roles: [:coordinator, :session, :api]}
      authorize_if OrgAdmin
      authorize_if {ScopedRead, or_principal: :principal_id}
    end

    policy action([:create, :update]) do
      authorize_if OrgAdmin
      authorize_if {SystemActor, roles: [:api, :jobs]}
    end

    policy action([:destroy]) do
      authorize_if OrgAdmin
      authorize_if {SystemActor, roles: [:jobs]}
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:principal_id, :prefix, :secret_sha256, :scopes, :target_ids, :expires_at]
      change Steward.Core.Targets.ApiKey.ValidateScopes
    end

    update :update do
      primary? true
      accept [:scopes, :target_ids, :last_used_at, :revoked_at]
      require_atomic? false
      change Steward.Core.Targets.ApiKey.ValidateScopes
    end
  end
end

defmodule Steward.Core.Branches.IdempotencyKey do
  @moduledoc "Doc 12 §2.3 `idempotency_keys`. 24 h TTL (doc 13 §8), purged by `IdempotencyPurge`."
  alias Steward.Core.Authz.Checks.{SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Branches,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "idempotency_keys"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :key, :string, allow_nil?: false
    attribute :request_sha256, :binary, allow_nil?: false
    attribute :response_status, :integer, allow_nil?: false
    attribute :response_body, :map, allow_nil?: false, default: %{}
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
  end

  relationships do
    belongs_to :principal, Steward.Core.Targets.Principal do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_key, [:principal_id, :key]
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: [:api]}
    end

    policy action([:create]) do
      authorize_if {SystemActor, roles: [:api]}
    end

    policy action([:destroy]) do
      authorize_if {SystemActor, roles: [:api, :jobs]}
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:principal_id, :key, :request_sha256, :response_status, :response_body, :expires_at]
    end
  end
end

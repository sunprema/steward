defmodule Steward.Core.Policies.PolicyAssertion do
  @moduledoc "Doc 12 §2.2 `policy_assertions` — one row per assertion so fire rates are per assertion (doc 06 §9)."
  alias Steward.Core.Authz.Checks.{Scope, ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Policies,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "policy_assertions"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :assertion_id, :string,
      allow_nil?: false,
      constraints: [match: ~r/^[a-z0-9][a-z0-9-]{0,63}$/]

    attribute :description, :string, allow_nil?: true
    attribute :sql, :string, allow_nil?: false, constraints: [max_length: 65_536]
    attribute :expect, :map, allow_nil?: false
    attribute :position, :integer, allow_nil?: false

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :policy_version, Steward.Core.Policies.PolicyVersion do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_assertion_id, [:policy_version_id, :assertion_id]
    identity :unique_position, [:policy_version_id, :position]
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: "policy:read", target: {:via, [:policy_version, :policy]}}
    end

    policy action([:create]) do
      authorize_if {SystemActor, roles: [:coordinator]}
      authorize_if {Scope, scope: "policy:write", target: {__MODULE__, :authz_target_id}}
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:policy_version_id, :assertion_id, :description, :sql, :expect, :position]
    end
  end

  @doc false
  def authz_target_id(subject) do
    alias Steward.Core.Authz.Subject

    with version_id when not is_nil(version_id) <- Subject.attr(subject, :policy_version_id),
         {:ok, version} <-
           Ash.get(Steward.Core.Policies.PolicyVersion, version_id,
             tenant: Subject.tenant(subject),
             authorize?: false
           ) do
      Subject.target_via(version, :policy_id, Steward.Core.Policies.Policy)
    else
      _ -> nil
    end
  end
end

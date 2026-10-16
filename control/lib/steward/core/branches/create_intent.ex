defmodule Steward.Core.Branches.CreateIntent do
  @moduledoc """
  Doc 12 §2.3 `create_intents` (doc 13 §6.1). `id` is the candidate branch
  ID; `branch_id` is only set once `Branch.create` (the checkpoint) commits.
  """
  alias Steward.Core.Authz.Checks.{ActsAs, Scope, ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Branches,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "create_intents"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :idempotency_key, :string, allow_nil?: false
    attribute :state, Steward.Core.Types.CreateIntentState, allow_nil?: false, default: :pending

    update_timestamp :updated_at
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

    belongs_to :branch, Steward.Core.Branches.Branch do
      attribute_writable? true
    end
  end

  identities do
    identity :unique_idempotency_key, [:principal_id, :idempotency_key]
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, or_principal: :principal_id}
    end

    # The caller-facing entry of branch creation (doc 13 §6.1): `branch:write` on the
    # target, acting as themselves.
    policy action([:create]) do
      authorize_if {SystemActor, roles: [:coordinator]}
      forbid_unless {ActsAs, attribute: :principal_id}
      authorize_if {Scope, scope: "branch:write"}
    end

    policy action([:commit, :fail, :supersede, :restart]) do
      authorize_if {SystemActor, roles: [:coordinator]}
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:target_id, :principal_id, :idempotency_key]
    end

    update :commit do
      accept [:branch_id]
      change set_attribute(:state, :committed)
    end

    # A retry of an attempt that did not complete: there is one intent per
    # (principal, idempotency key), so the next attempt starts it again.
    update :restart do
      accept []
      change set_attribute(:state, :pending)
    end

    update :fail do
      accept []
      change set_attribute(:state, :failed)
    end

    update :supersede do
      accept []
      change set_attribute(:state, :superseded)
    end
  end
end

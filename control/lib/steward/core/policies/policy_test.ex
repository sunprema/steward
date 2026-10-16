defmodule Steward.Core.Policies.PolicyTest do
  @moduledoc """
  Doc 12 §2.3 `policy_tests`. Tests belong to the policy, not the version, so
  they carry forward (doc 06 §4.3); mirrored as YAML under
  `control/test/policies/<target>/<policy>/<test>.yaml` (doc 06 §5.5).
  """
  alias Steward.Core.Authz.Checks.{Scope, ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Policies,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "policy_tests"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :name, :string, allow_nil?: false
    attribute :fixture, :map, allow_nil?: false
    attribute :expected_outcome, Steward.Core.Types.VerdictOutcome, allow_nil?: false
    attribute :expected_fired, {:array, :string}, allow_nil?: false, default: []
    attribute :expected_counts, :map, allow_nil?: false, default: %{}
    attribute :last_result, :string, allow_nil?: true
    attribute :last_run_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :policy, Steward.Core.Policies.Policy do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :last_run_version, Steward.Core.Policies.PolicyVersion do
      attribute_writable? true
    end
  end

  identities do
    identity :unique_name, [:policy_id, :name]
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: "policy:read", target: {:via, [:policy]}}
    end

    policy action([:create, :update, :destroy]) do
      authorize_if {Scope, scope: "policy:write", target: {__MODULE__, :authz_target_id}}
    end

    policy action([:record_run]) do
      authorize_if {SystemActor, roles: [:coordinator]}
      authorize_if {Scope, scope: "policy:read", target: {__MODULE__, :authz_target_id}}
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:policy_id, :name, :fixture, :expected_outcome, :expected_fired, :expected_counts]
    end

    update :update do
      primary? true
      accept [:fixture, :expected_outcome, :expected_fired, :expected_counts]
    end

    update :record_run do
      accept [:last_run_version_id, :last_result]
      change set_attribute(:last_run_at, &DateTime.utc_now/0)
    end
  end

  @doc false
  def authz_target_id(subject),
    do: Steward.Core.Authz.Subject.target_via(subject, :policy_id, Steward.Core.Policies.Policy)
end

defmodule Steward.Core.Policies.PolicyVersion do
  @moduledoc """
  Doc 12 §2.2 `policy_versions`; immutable except `state` and the
  activation/retirement columns. `AshStateMachine` transitions declared
  literally from doc 06 §5.2's `[*] → draft → active → retired`.
  """
  alias Steward.Core.Authz.Checks.{ActsAs, Scope, ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Policies,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine]

  postgres do
    table "policy_versions"
    repo Steward.Repo

    identity_wheres_to_sql one_active_per_policy: "state = 'active'"

    check_constraints do
      check_constraint :state, "active_was_checked",
        check: """
        state = 'draft' OR (static_check_passed_at IS NOT NULL AND tests_passed_at IS NOT NULL
          AND activated_by IS NOT NULL AND activated_at IS NOT NULL)
        """

      check_constraint :retired_at, "retired_has_time",
        check: "(state = 'retired') = (retired_at IS NOT NULL)"
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  state_machine do
    initial_states [:draft]
    default_initial_state :draft
    state_attribute :state

    transitions do
      transition :activate, from: :draft, to: :active
      transition :retire, from: :active, to: :retired
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :version, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :state, Steward.Core.Types.PolicyVersionState, allow_nil?: false, default: :draft
    attribute :yaml, :string, allow_nil?: false, constraints: [max_length: 262_144]
    attribute :name, :string, allow_nil?: false
    attribute :scope, :map, allow_nil?: false
    # :hold | :block only (doc 12 §2.2 CHECK); :"auto-merge" is a VerdictOutcome
    # value but never valid here, enforced by a hand-written migration CHECK.
    attribute :outcome, Steward.Core.Types.VerdictOutcome, allow_nil?: false
    attribute :referenced_relations, {:array, :string}, allow_nil?: false, default: []
    attribute :static_check_passed_at, :utc_datetime_usec, allow_nil?: true
    attribute :tests_passed_at, :utc_datetime_usec, allow_nil?: true
    attribute :activated_at, :utc_datetime_usec, allow_nil?: true
    attribute :retired_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :policy, Steward.Core.Policies.Policy do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :saved_by_principal, Steward.Core.Targets.Principal do
      source_attribute :saved_by
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :activated_by_principal, Steward.Core.Targets.Principal do
      source_attribute :activated_by
      allow_nil? true
      attribute_writable? true
    end
  end

  identities do
    identity :unique_version, [:policy_id, :version]
    identity :one_active_per_policy, [:policy_id], where: expr(state == :active)
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: "policy:read", target: {:via, [:policy]}}
    end

    # `saved_by` feeds the activation separation rule (doc 15 §3.3), so it may only name the caller.
    policy action([:create]) do
      forbid_unless {ActsAs, attribute: :saved_by}
      authorize_if {Scope, scope: "policy:write", target: {__MODULE__, :authz_target_id}}
    end

    policy action([:record_static_check, :record_tests_passed]) do
      authorize_if {SystemActor, roles: [:coordinator, :jobs]}
      authorize_if {Scope, scope: "policy:write", target: {__MODULE__, :authz_target_id}}
    end

    # Activation needs `policy:admin` on the target; refusing self-activation
    # (`policy_activation_refused`) is a domain rule, added with the Policy engine (E5).
    policy action([:activate]) do
      authorize_if {Scope, scope: "policy:admin", target: {__MODULE__, :authz_target_id}}
    end

    policy action([:retire]) do
      authorize_if {SystemActor, roles: [:coordinator]}
      authorize_if {Scope, scope: "policy:admin", target: {__MODULE__, :authz_target_id}}
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :policy_id,
        :version,
        :yaml,
        :name,
        :scope,
        :outcome,
        :referenced_relations,
        :saved_by
      ]

      change {Steward.Core.Audit.AppendEvent,
              type: "policy.version_saved",
              aggregate_type: "policy",
              aggregate_id: & &1.policy_id,
              payload: &__MODULE__.saved_payload/2}
    end

    update :record_static_check do
      accept []
      change set_attribute(:static_check_passed_at, &DateTime.utc_now/0)
    end

    update :record_tests_passed do
      accept []
      change set_attribute(:tests_passed_at, &DateTime.utc_now/0)
    end

    update :activate do
      accept [:activated_by]
      require_atomic? false
      change transition_state(:active)
      change set_attribute(:activated_at, &DateTime.utc_now/0)

      change {Steward.Core.Audit.AppendEvent,
              type: "policy.activated",
              aggregate_type: "policy",
              aggregate_id: & &1.policy_id,
              payload: &__MODULE__.activated_payload/2}
    end

    update :retire do
      accept []
      require_atomic? false
      change transition_state(:retired)
      change set_attribute(:retired_at, &DateTime.utc_now/0)

      change {Steward.Core.Audit.AppendEvent,
              type: "policy.retired",
              aggregate_type: "policy",
              aggregate_id: & &1.policy_id,
              payload: &__MODULE__.activated_payload/2}
    end
  end

  def saved_payload(_changeset, record) do
    %{
      policy_version_id: record.id,
      version: record.version,
      tests_passed: not is_nil(record.tests_passed_at)
    }
  end

  def activated_payload(_changeset, record), do: %{policy_version_id: record.id}

  @doc false
  # The target a version belongs to, through its policy (doc 15 §3.2).
  def authz_target_id(subject),
    do: Steward.Core.Authz.Subject.target_via(subject, :policy_id, Steward.Core.Policies.Policy)
end

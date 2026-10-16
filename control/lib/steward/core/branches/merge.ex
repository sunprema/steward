defmodule Steward.Core.Branches.Merge do
  @moduledoc """
  Doc 12 §2.2 `merges`; `id` equals the compensation ID (doc 13 §8).
  Transitions from doc 13 §6.5/§6.6, doc 12 §4: `pending → applied`,
  `pending → failed`, `applied → compensated`.
  """
  alias Steward.Core.Authz.Checks.{ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Branches,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine]

  postgres do
    table "merges"
    repo Steward.Repo

    identity_wheres_to_sql unique_pending_per_target: "state = 'pending'",
                           unique_live_per_changeset: "state != 'failed'"

    references do
      reference :target, match_tenant?: true
      reference :branch, match_tenant?: true
      reference :changeset, match_tenant?: true
    end

    check_constraints do
      check_constraint :compensation_persisted_at, "applied_has_compensation",
        check: "state NOT IN ('applied','compensated') OR compensation_persisted_at IS NOT NULL"

      check_constraint :reason, "failed_has_reason",
        check: "(state = 'failed') = (reason IS NOT NULL AND failed_at IS NOT NULL)"

      check_constraint :compensation_persisted_at, "failed_before_checkpoint",
        check: "state <> 'failed' OR compensation_persisted_at IS NULL"

      check_constraint :compensated_at, "compensated_has_revert",
        check:
          "state <> 'compensated' OR (compensated_at IS NOT NULL AND compensated_by_branch_id IS NOT NULL)"

      check_constraint :progress_applied, "progress_bounds",
        check: "progress_applied >= 0 AND progress_applied <= progress_total"
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending
    state_attribute :state

    transitions do
      transition :complete, from: :pending, to: :applied
      transition :fail, from: :pending, to: :failed
      transition :compensate, from: :applied, to: :compensated
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :state, Steward.Core.Types.MergeState, allow_nil?: false, default: :pending
    attribute :reason, Steward.Core.Types.LifecycleReason, allow_nil?: true
    attribute :progress_applied, :integer, allow_nil?: false, default: 0
    attribute :progress_total, :integer, allow_nil?: false, default: 0
    attribute :progress_updated_at, :utc_datetime_usec, allow_nil?: true
    attribute :compensation_persisted_at, :utc_datetime_usec, allow_nil?: true
    attribute :applied_at, :utc_datetime_usec, allow_nil?: true
    attribute :compensated_at, :utc_datetime_usec, allow_nil?: true
    attribute :failed_at, :utc_datetime_usec, allow_nil?: true
    attribute :stalled_alerted_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :target, Steward.Core.Targets.Target do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :branch, Steward.Core.Branches.Branch do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :changeset, Steward.Core.Branches.Changeset do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :compensated_by_branch, Steward.Core.Branches.Branch do
      attribute_writable? true
    end
  end

  identities do
    identity :unique_pending_per_target, [:target_id], where: expr(state == :pending)
    identity :unique_live_per_changeset, [:changeset_id], where: expr(state != :failed)
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: "changeset:read"}
    end

    policy action([:create, :record_compensation_persisted, :complete, :fail, :compensate]) do
      authorize_if {SystemActor, roles: [:coordinator]}
    end

    policy action([:record_progress]) do
      authorize_if {SystemActor, roles: [:session, :coordinator]}
    end

    policy action([:alert_stalled]) do
      authorize_if {SystemActor, roles: [:jobs]}
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:target_id, :branch_id, :changeset_id]
    end

    update :record_compensation_persisted do
      accept []
      require_atomic? false
      change set_attribute(:compensation_persisted_at, &DateTime.utc_now/0)

      change {Steward.Core.Audit.AppendEvent,
              type: "merge.checkpointed",
              aggregate_type: "merge",
              payload: &__MODULE__.checkpointed_payload/2}
    end

    update :record_progress do
      accept [:progress_applied, :progress_total]
      change set_attribute(:progress_updated_at, &DateTime.utc_now/0)
    end

    update :complete do
      accept []
      require_atomic? false
      change transition_state(:applied)
      change set_attribute(:applied_at, &DateTime.utc_now/0)

      change {Steward.Core.Audit.AppendEvent,
              type: "merge.applied",
              aggregate_type: "merge",
              payload: &__MODULE__.applied_payload/2}
    end

    update :fail do
      accept [:reason]
      require_atomic? false
      change transition_state(:failed)
      change set_attribute(:failed_at, &DateTime.utc_now/0)

      change {Steward.Core.Audit.AppendEvent,
              type: "merge.failed", aggregate_type: "merge", payload: &__MODULE__.failed_payload/2}
    end

    update :compensate do
      accept [:compensated_by_branch_id]
      require_atomic? false
      change transition_state(:compensated)
      change set_attribute(:compensated_at, &DateTime.utc_now/0)

      change {Steward.Core.Audit.AppendEvent,
              type: "merge.compensated",
              aggregate_type: "merge",
              payload: &__MODULE__.compensated_payload/2}
    end

    update :alert_stalled do
      accept []
      require_atomic? false
      change set_attribute(:stalled_alerted_at, &DateTime.utc_now/0)

      change {Steward.Core.Audit.AppendEvent,
              type: "merge.stalled",
              aggregate_type: "merge",
              payload: &__MODULE__.stalled_payload/2}
    end
  end

  def checkpointed_payload(_changeset, record) do
    %{row_count: record.progress_total}
  end

  def applied_payload(_changeset, record) do
    %{rows_applied: record.progress_applied}
  end

  def failed_payload(changeset, record) do
    %{reason: record.reason, before_checkpoint: is_nil(changeset.data.compensation_persisted_at)}
  end

  def compensated_payload(_changeset, record) do
    %{revert_branch_id: record.compensated_by_branch_id}
  end

  def stalled_payload(_changeset, record) do
    %{progress_applied: record.progress_applied, progress_total: record.progress_total}
  end
end

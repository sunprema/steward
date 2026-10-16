defmodule Steward.Core.Branches.Branch do
  @moduledoc """
  Doc 12 §2.2 `branches`. `AshStateMachine` transitions declared literally
  from doc 13 §2's state diagram, which is authoritative over §2.1's prose
  table where the two disagree (the table's "proposed → open" row lists
  `stale_base` as a trigger; §6.5 and the table's own "merging → proposed"
  row make clear `stale_base` only ever returns a branch from `merging` to
  `proposed`, never from `proposed` to `open` — a documentation bug fixed
  alongside this code per doc 18 §6, since doc 13 is still `Draft`).
  """
  alias Steward.Core.Authz.Checks.{ActsAs, Scope, ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Branches,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer,
    notifiers: [Steward.Core.Branches.Notifier],
    extensions: [AshStateMachine, AshOban]

  postgres do
    table "branches"
    repo Steward.Repo

    # Doc 12 §1: FKs that could cross an org are composite on (org_id, id).
    references do
      reference :target, match_tenant?: true
      reference :principal, match_tenant?: true
    end

    check_constraints do
      check_constraint :state, "terminal_has_reason",
        check: """
        state NOT IN ('merged','rejected','abandoned','closed')
        OR (reason IS NOT NULL AND terminal_at IS NOT NULL
            AND (terminal_by_principal_id IS NOT NULL OR terminal_by_job IS NOT NULL))
        """

      check_constraint :ttl_expires_at, "open_has_ttl",
        check: "state <> 'open' OR ttl_expires_at IS NOT NULL"

      check_constraint :overlay_released_at, "released_only_when_closed",
        check: "overlay_released_at IS NULL OR state = 'closed'"

      check_constraint :overlay_released_at, "closed_is_released",
        check: "state <> 'closed' OR overlay_released_at IS NOT NULL"

      check_constraint :merge_wait, "merge_wait_only_proposed",
        check: "NOT merge_wait OR state = 'proposed'"
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  state_machine do
    initial_states [:open]
    default_initial_state :open
    state_attribute :state

    transitions do
      transition :propose, from: :open, to: :proposed
      transition :return_to_open, from: :proposed, to: :open
      transition :withdraw, from: :proposed, to: :open
      transition :start_merge, from: :proposed, to: :merging
      transition :reject, from: :proposed, to: :rejected
      transition :abandon, from: [:open, :proposed], to: :abandoned
      transition :expire_ttl, from: :open, to: :abandoned
      transition :reject_blocked, from: :proposed, to: :rejected
      transition :lose_snapshot, from: [:open, :proposed, :merging], to: :abandoned
      transition :complete_merge, from: :merging, to: :merged
      transition :fail_merge, from: :merging, to: :proposed
      transition :close, from: [:merged, :rejected, :abandoned], to: :closed
    end
  end

  # Scheduled work that is pure Ash (doc 07 §5.0, §6). The jobs that call into the
  # coordinator are plain Oban workers in `Steward.Jobs`.
  oban do
    list_tenants Steward.Core.Targets.TenantList
    use_tenant_from_record? true

    triggers do
      # Doc 13 §6.7: an `open` branch not proposed within its TTL is abandoned.
      trigger :expire_ttl do
        action :expire_ttl
        where expr(state == :open and not is_nil(ttl_expires_at) and ttl_expires_at < now())
        scheduler_cron "* * * * *"
        queue :branch_expire_ttl
        worker_module_name Steward.Core.Branches.Workers.ExpireTtl
        scheduler_module_name Steward.Core.Branches.Schedulers.ExpireTtl
        default_actor Steward.Core.Authz.System.jobs()
      end

      # Doc 13 §6.3 f7: every `block` verdict whose branch is not `rejected` is set `rejected`.
      trigger :reject_blocked do
        action :reject_blocked

        where expr(
                state == :proposed and
                  exists(changesets, state == :evaluated and exists(verdict, outcome == :block))
              )

        scheduler_cron "* * * * *"
        queue :branch_reject_blocked
        worker_module_name Steward.Core.Branches.Workers.RejectBlocked
        scheduler_module_name Steward.Core.Branches.Schedulers.RejectBlocked
        default_actor Steward.Core.Authz.System.jobs()
      end
    end
  end

  attributes do
    # Writable: the control plane picks the branch id before asking the data plane
    # for an overlay, and the row is written last with that same id (doc 13 §6.1).
    uuid_v7_primary_key :id, writable?: true
    attribute :org_id, :uuid, allow_nil?: false

    attribute :overlay_id, :uuid, allow_nil?: false
    attribute :base_snapshot_ref, :string, allow_nil?: false, sensitive?: true
    attribute :base_snapshot_fidelity, Steward.Core.Types.SnapshotFidelity, allow_nil?: false
    attribute :base_snapshot_at, :utc_datetime_usec, allow_nil?: false
    attribute :state, Steward.Core.Types.BranchState, allow_nil?: false, default: :open
    attribute :reason, Steward.Core.Types.LifecycleReason, allow_nil?: true
    attribute :idempotency_key, :string, allow_nil?: false
    attribute :ttl_expires_at, :utc_datetime_usec, allow_nil?: true
    attribute :held_ttl_expires_at, :utc_datetime_usec, allow_nil?: true
    attribute :proposed_at, :utc_datetime_usec, allow_nil?: true
    attribute :last_heartbeat_at, :utc_datetime_usec, allow_nil?: true
    attribute :heartbeat_lost, :boolean, allow_nil?: false, default: false
    attribute :merge_wait, :boolean, allow_nil?: false, default: false
    attribute :overlay_rows, :integer, allow_nil?: false, default: 0
    attribute :overlay_bytes, :integer, allow_nil?: false, default: 0
    attribute :evidence_gap, :integer, allow_nil?: false, default: 0
    attribute :terminal_at, :utc_datetime_usec, allow_nil?: true
    attribute :terminal_by_job, :string, allow_nil?: true
    attribute :overlay_released_at, :utc_datetime_usec, allow_nil?: true
    attribute :lock_version, :integer, allow_nil?: false, default: 0

    create_timestamp :inserted_at
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

    belongs_to :revert_of_merge, Steward.Core.Branches.Merge do
      attribute_writable? true
    end

    has_many :changesets, Steward.Core.Branches.Changeset do
      destination_attribute :branch_id
    end

    belongs_to :terminal_by_principal, Steward.Core.Targets.Principal do
      source_attribute :terminal_by_principal_id
      attribute_writable? true
    end
  end

  identities do
    identity :unique_overlay_id, [:overlay_id], all_tenants?: true
    identity :unique_id_overlay_id, [:id, :overlay_id], all_tenants?: true
    identity :unique_idempotency_key, [:principal_id, :idempotency_key]
    identity :unique_org_id, [:id]
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: "changeset:read", or_principal: :principal_id}
    end

    # Created by the CreateBranch reactor with data-plane facts (overlay, snapshot); an API
    # caller's authority is checked on `CreateIntent.create` (branch:write).
    policy action([:create]) do
      authorize_if {SystemActor, roles: [:coordinator]}
    end

    policy action([:propose]) do
      authorize_if {SystemActor, roles: [:coordinator]}
      forbid_unless {ActsAs, attribute: :principal_id}
      authorize_if {Scope, scope: "branch:propose"}
    end

    # Withdraw: owner only (doc 13 §7). The coordinator also returns branches to open
    # (retry-allowed rejection, stale base).
    policy action([:return_to_open]) do
      authorize_if {SystemActor, roles: [:coordinator]}
    end

    policy action([:withdraw]) do
      authorize_if {SystemActor, roles: [:coordinator]}
      forbid_unless {ActsAs, attribute: :principal_id}
      authorize_if {Scope, scope: "branch:write"}
    end

    # Owner may abandon their own branch; `target:admin` may abandon any (doc 15 §3.2).
    policy action([:abandon]) do
      authorize_if {SystemActor, roles: [:coordinator, :jobs]}
      authorize_if {Scope, scope: "target:admin"}
      forbid_unless {ActsAs, attribute: :principal_id}
      authorize_if {Scope, scope: "branch:write"}
    end

    policy action([:expire_ttl, :reject_blocked]) do
      authorize_if {SystemActor, roles: [:jobs]}
    end

    policy action([:lose_snapshot]) do
      authorize_if {SystemActor, roles: [:coordinator, :session]}
    end

    policy action([:heartbeat_touch]) do
      authorize_if {SystemActor, roles: [:session, :coordinator]}
    end

    policy action([:reject, :start_merge, :complete_merge, :fail_merge]) do
      authorize_if {SystemActor, roles: [:coordinator]}
    end

    policy action([:close]) do
      authorize_if {SystemActor, roles: [:jobs, :coordinator]}
    end
  end

  actions do
    defaults [:read]

    # Every branch the coordinator keeps a process for (doc 07 §4: BootSweeper
    # streams this). Terminal branches have none.
    read :non_terminal do
      pagination keyset?: true, required?: false
      filter expr(state in [:open, :proposed, :merging])
    end

    create :create do
      primary? true

      accept [
        :id,
        :target_id,
        :principal_id,
        :overlay_id,
        :base_snapshot_ref,
        :base_snapshot_fidelity,
        :base_snapshot_at,
        :idempotency_key,
        :ttl_expires_at,
        :revert_of_merge_id
      ]

      change {Steward.Core.Audit.AppendEvent,
              type: "branch.created",
              aggregate_type: "branch",
              payload: &__MODULE__.created_payload/2}
    end

    update :propose do
      change optimistic_lock(:lock_version)
      accept []
      require_atomic? false
      argument :rationale, :string, allow_nil?: true, constraints: [max_length: 4096]
      argument :trigger, :string, allow_nil?: true, default: "propose"
      change transition_state(:proposed)
      change set_attribute(:proposed_at, &DateTime.utc_now/0)
      change Steward.Core.Branches.Changes.OpenChangeset

      change {Steward.Core.Audit.AppendEvent,
              type: "branch.proposed",
              aggregate_type: "branch",
              payload: &__MODULE__.proposed_payload/2}
    end

    # Owner-facing `proposed → open` (doc 13 §5, §6.3): the live changeset is
    # superseded (`withdrawn`). `return_to_open` is the same edge for the system
    # (a reactor unwinding, reject-with-retry) and carries its own reason.
    update :withdraw do
      change optimistic_lock(:lock_version)
      accept []
      require_atomic? false
      change transition_state(:open)
      change set_attribute(:merge_wait, false)
      change {Steward.Core.Branches.Changes.LeaveProposed, supersede: :withdrawn, queue: true}

      change {Steward.Core.Audit.AppendEvent,
              type: "branch.withdrawn",
              aggregate_type: "branch",
              payload: &__MODULE__.no_payload/2}
    end

    update :return_to_open do
      change optimistic_lock(:lock_version)
      accept [:reason]
      validate present(:reason)
      require_atomic? false
      change transition_state(:open)
      change set_attribute(:merge_wait, false)
      change {Steward.Core.Branches.Changes.LeaveProposed, supersede: :branch_reason, queue: true}

      change {Steward.Core.Audit.AppendEvent,
              type: "branch.returned_to_open",
              aggregate_type: "branch",
              payload: &__MODULE__.reason_payload/2}
    end

    # The TTL job's transition (doc 13 §6.7). Not the owner's `abandon`: the actor is a
    # job, the reason is fixed, and the job is named instead of a principal.
    update :expire_ttl do
      change optimistic_lock(:lock_version)
      accept []
      require_atomic? false
      change transition_state(:abandoned)
      change set_attribute(:reason, :ttl_expired)
      change set_attribute(:terminal_by_job, "ttl")
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
      change {Steward.Core.Branches.Changes.LeaveProposed, supersede: :branch_reason, queue: true}

      change {Steward.Core.Audit.AppendEvent,
              type: "branch.abandoned",
              aggregate_type: "branch",
              payload: &__MODULE__.abandoned_payload/2}
    end

    # The reconciliation of a `block` verdict whose follow-up never ran (doc 13 §6.3 f7).
    update :reject_blocked do
      change optimistic_lock(:lock_version)
      accept []
      require_atomic? false
      change transition_state(:rejected)
      change set_attribute(:reason, :verdict_block)
      change set_attribute(:terminal_by_job, "reconcile")
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
      change {Steward.Core.Branches.Changes.LeaveProposed, queue: true}

      change {Steward.Core.Audit.AppendEvent,
              type: "branch.rejected",
              aggregate_type: "branch",
              payload: &__MODULE__.reason_payload/2}
    end

    update :start_merge do
      change optimistic_lock(:lock_version)
      accept [:reason]
      require_atomic? false
      argument :merge_id, :uuid, allow_nil?: false
      change transition_state(:merging)

      change {Steward.Core.Audit.AppendEvent,
              type: "branch.merging",
              aggregate_type: "branch",
              payload: &__MODULE__.start_merge_payload/2}
    end

    update :reject do
      change optimistic_lock(:lock_version)
      accept [:reason, :terminal_by_principal_id, :terminal_by_job]
      require_atomic? false
      change transition_state(:rejected)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
      change {Steward.Core.Branches.Changes.LeaveProposed, queue: true}

      change {Steward.Core.Audit.AppendEvent,
              type: "branch.rejected",
              aggregate_type: "branch",
              payload: &__MODULE__.reason_payload/2}
    end

    update :abandon do
      change optimistic_lock(:lock_version)
      accept [:reason, :terminal_by_principal_id, :terminal_by_job]
      require_atomic? false
      change transition_state(:abandoned)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
      change {Steward.Core.Branches.Changes.LeaveProposed, supersede: :branch_reason, queue: true}

      change {Steward.Core.Audit.AppendEvent,
              type: "branch.abandoned",
              aggregate_type: "branch",
              payload: &__MODULE__.abandoned_payload/2}
    end

    update :lose_snapshot do
      change optimistic_lock(:lock_version)
      accept [:reason, :terminal_by_job]
      require_atomic? false
      change transition_state(:abandoned)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)
      change {Steward.Core.Branches.Changes.LeaveProposed, supersede: :branch_reason, queue: true}

      change {Steward.Core.Audit.AppendEvent,
              type: "branch.abandoned",
              aggregate_type: "branch",
              payload: &__MODULE__.abandoned_payload/2}
    end

    update :complete_merge do
      change optimistic_lock(:lock_version)
      accept [:terminal_by_job]
      require_atomic? false
      argument :merge_id, :uuid, allow_nil?: false
      change transition_state(:merged)
      change set_attribute(:reason, :merge_applied)
      change set_attribute(:terminal_at, &DateTime.utc_now/0)

      change {Steward.Core.Audit.AppendEvent,
              type: "branch.merged",
              aggregate_type: "branch",
              payload: &__MODULE__.merge_id_payload/2}
    end

    update :fail_merge do
      change optimistic_lock(:lock_version)
      accept [:reason]
      change transition_state(:proposed)
    end

    update :close do
      change optimistic_lock(:lock_version)
      accept [:overlay_released_at, :terminal_by_job]
      require_atomic? false
      change transition_state(:closed)
      change set_attribute(:reason, :retention_elapsed)

      change {Steward.Core.Audit.AppendEvent,
              type: "branch.closed",
              aggregate_type: "branch",
              payload: &__MODULE__.closed_payload/2}
    end

    update :heartbeat_touch do
      accept [:last_heartbeat_at, :heartbeat_lost, :overlay_rows, :overlay_bytes, :evidence_gap]
      require_atomic? false
    end
  end

  def created_payload(_changeset, record) do
    %{
      principal_id: record.principal_id,
      overlay_id: record.overlay_id,
      base_snapshot_fidelity: record.base_snapshot_fidelity,
      revert_of_merge_id: record.revert_of_merge_id,
      ttl_expires_at: record.ttl_expires_at
    }
  end

  def reason_payload(_changeset, record), do: %{reason: record.reason}

  def no_payload(_changeset, _record), do: %{}

  def proposed_payload(_changeset, record), do: %{proposed_at: record.proposed_at}

  def abandoned_payload(changeset, record) do
    %{from_state: changeset.data.state, reason: record.reason}
  end

  def start_merge_payload(changeset, record) do
    %{merge_id: Ash.Changeset.get_argument(changeset, :merge_id), via: record.reason}
  end

  def merge_id_payload(changeset, _record) do
    %{merge_id: Ash.Changeset.get_argument(changeset, :merge_id)}
  end

  def closed_payload(_changeset, record), do: %{overlay_released_at: record.overlay_released_at}
end

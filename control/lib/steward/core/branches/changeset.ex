defmodule Steward.Core.Branches.Changeset do
  @moduledoc "Doc 12 §2.2 `changesets`. Transitions from doc 13 §3: `computing → evaluated`, `{computing,evaluated} → superseded`."
  alias Steward.Core.Authz.Checks.{ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Branches,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine]

  postgres do
    table "changesets"
    repo Steward.Repo

    identity_wheres_to_sql one_live_per_branch: "state != 'superseded'"

    references do
      reference :branch, match_tenant?: true
      reference :target, match_tenant?: true
    end

    custom_statements do
      statement :validate_boundary_json_fn do
        up Steward.Core.Audit.BoundaryJson.create_function_sql()
        down Steward.Core.Audit.BoundaryJson.drop_function_sql()
      end

      statement :validate_boundary_json_summary do
        up Steward.Core.Audit.BoundaryJson.create_trigger_sql("changesets", "summary")
        down Steward.Core.Audit.BoundaryJson.drop_trigger_sql("changesets", "summary")
      end

      statement :validate_boundary_json_impact do
        up Steward.Core.Audit.BoundaryJson.create_trigger_sql("changesets", "impact")
        down Steward.Core.Audit.BoundaryJson.drop_trigger_sql("changesets", "impact")
      end
    end

    check_constraints do
      check_constraint :state, "evaluated_has_layers",
        check: """
        state <> 'evaluated' OR (summary IS NOT NULL AND impact IS NOT NULL
          AND row_delta_digest IS NOT NULL AND evaluated_at IS NOT NULL)
        """

      check_constraint :superseded_reason, "superseded_has_reason",
        check: "(state = 'superseded') = (superseded_reason IS NOT NULL)"

      check_constraint :summary, "summary_bounded",
        check: "summary IS NULL OR pg_column_size(summary) <= 262144"

      check_constraint :impact, "impact_bounded",
        check: "impact IS NULL OR pg_column_size(impact) <= 65536"
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  state_machine do
    initial_states [:computing]
    default_initial_state :computing
    state_attribute :state

    transitions do
      transition :evaluate, from: :computing, to: :evaluated
      transition :supersede, from: [:computing, :evaluated], to: :superseded
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :sequence, :integer, allow_nil?: false
    attribute :state, Steward.Core.Types.ChangesetState, allow_nil?: false, default: :computing
    attribute :superseded_reason, Steward.Core.Types.LifecycleReason, allow_nil?: true

    # propose | reevaluate | stale_base | revert | edit (doc 13 §3); CHECK added by hand migration.
    attribute :trigger, :string, allow_nil?: false
    attribute :rationale, :string, allow_nil?: true, constraints: [max_length: 4096]
    attribute :summary, :map, allow_nil?: true
    attribute :impact, :map, allow_nil?: true
    attribute :conflicts_count, :integer, allow_nil?: false, default: 0
    attribute :partial_keys_count, :integer, allow_nil?: false, default: 0
    # complete | partial (doc 09 §5.1); CHECK added by hand migration.
    attribute :reversible, :string, allow_nil?: true
    attribute :row_delta_digest, :binary, allow_nil?: true
    attribute :evidence_refs, {:array, :map}, allow_nil?: false, default: []
    attribute :evidence_gap, :integer, allow_nil?: false, default: 0
    attribute :policy_version_set, {:array, :uuid}, allow_nil?: false, default: []
    attribute :compute_attempts, :integer, allow_nil?: false, default: 0
    attribute :computed_at, :utc_datetime_usec, allow_nil?: true
    attribute :evaluated_at, :utc_datetime_usec, allow_nil?: true
    attribute :lock_version, :integer, allow_nil?: false, default: 0

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :branch, Steward.Core.Branches.Branch do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :target, Steward.Core.Targets.Target do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :superseded_by, __MODULE__ do
      attribute_writable? true
    end
  end

  identities do
    identity :unique_sequence, [:branch_id, :sequence]
    identity :one_live_per_branch, [:branch_id], where: expr(state != :superseded)
    identity :unique_org_id, [:id]
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: "changeset:read"}
    end

    policy action([:create, :evaluate]) do
      authorize_if {SystemActor, roles: [:coordinator]}
    end

    policy action([:record_computed]) do
      authorize_if {SystemActor, roles: [:coordinator, :session]}
    end

    policy action([:bump_compute_attempts, :supersede]) do
      authorize_if {SystemActor, roles: [:coordinator, :jobs]}
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:branch_id, :target_id, :sequence, :trigger, :rationale, :policy_version_set]

      change {Steward.Core.Audit.AppendEvent,
              type: "changeset.computing",
              aggregate_type: "changeset",
              payload: &__MODULE__.computing_payload/2}
    end

    update :record_computed do
      accept [
        :summary,
        :impact,
        :conflicts_count,
        :partial_keys_count,
        :reversible,
        :row_delta_digest,
        :evidence_refs,
        :evidence_gap
      ]

      change set_attribute(:computed_at, &DateTime.utc_now/0)
    end

    update :evaluate do
      accept []
      require_atomic? false
      change transition_state(:evaluated)
      change set_attribute(:evaluated_at, &DateTime.utc_now/0)

      change {Steward.Core.Audit.AppendEvent,
              type: "changeset.evaluated",
              aggregate_type: "changeset",
              payload: &__MODULE__.evaluated_payload/2}
    end

    update :bump_compute_attempts do
      accept []
      require_atomic? false
      change atomic_update(:compute_attempts, expr(compute_attempts + 1))
    end

    update :supersede do
      accept [:superseded_reason, :superseded_by_id]
      require_atomic? false
      change transition_state(:superseded)

      change {Steward.Core.Audit.AppendEvent,
              type: "changeset.superseded",
              aggregate_type: "changeset",
              payload: &__MODULE__.superseded_payload/2}
    end
  end

  def computing_payload(_changeset, record) do
    %{branch_id: record.branch_id, sequence: record.sequence, trigger: record.trigger}
  end

  def evaluated_payload(_changeset, record) do
    %{
      conflicts_count: record.conflicts_count,
      reversible: record.reversible,
      policy_version_ids: record.policy_version_set
    }
  end

  def superseded_payload(_changeset, record) do
    %{superseded_by_id: record.superseded_by_id, reason: record.superseded_reason}
  end
end

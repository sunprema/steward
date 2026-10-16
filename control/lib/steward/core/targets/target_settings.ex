defmodule Steward.Core.Targets.TargetSettings do
  @moduledoc "Doc 12 §2.3 `target_settings` — 1:1 with `Target`, keyed by `target_id`."
  alias Steward.Core.Authz.Checks.{Scope, ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "target_settings"
    repo Steward.Repo

    check_constraints do
      # Doc 13 §9: compensation is never GC'd while revertable.
      check_constraint :compensation_retention, "compensation_covers_revert_window",
        check: "compensation_retention >= revert_window"

      check_constraint :uncovered_changeset_verdict, "uncovered_changeset_verdict_valid",
        check: "uncovered_changeset_verdict IN ('hold', 'auto-merge')"
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    attribute :target_id, :uuid, primary_key?: true, allow_nil?: false
    attribute :org_id, :uuid, allow_nil?: false

    attribute :branch_ttl, :duration, allow_nil?: false, default: &__MODULE__.default_branch_ttl/0
    attribute :held_ttl, :duration, allow_nil?: true

    attribute :overlay_retention, :duration,
      allow_nil?: false,
      default: &__MODULE__.default_overlay_retention/0

    attribute :compensation_retention, :duration,
      allow_nil?: false,
      default: &__MODULE__.default_compensation_retention/0

    attribute :revert_window, :duration,
      allow_nil?: false,
      default: &__MODULE__.default_compensation_retention/0

    # Only :hold | :"auto-merge" are valid (doc 12 §2.3 CHECK, added by hand migration);
    # :block is a VerdictOutcome value but never a valid setting here.
    attribute :uncovered_changeset_verdict, Steward.Core.Types.VerdictOutcome,
      allow_nil?: false,
      default: :hold

    attribute :summary_values_allowed, :map, allow_nil?: false, default: %{}
    attribute :assertion_budget_s, :integer, allow_nil?: false, default: 60
    attribute :assertion_timeout_s, :integer, allow_nil?: false, default: 20
    attribute :impact_timeout_s, :integer, allow_nil?: false, default: 30

    attribute :heartbeat_lost_after, :duration,
      allow_nil?: false,
      default: &__MODULE__.default_heartbeat_lost_after/0

    attribute :merge_lease, :duration,
      allow_nil?: false,
      default: &__MODULE__.default_merge_lease/0

    attribute :merge_stall_budget, :duration,
      allow_nil?: false,
      default: &__MODULE__.default_merge_stall_budget/0

    attribute :separate_approval, :boolean, allow_nil?: false, default: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :target, Steward.Core.Targets.Target do
      source_attribute :target_id
      define_attribute? false
      allow_nil? false
      primary_key? true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: :any}
    end

    policy action([:create]) do
      authorize_if {SystemActor, roles: [:coordinator, :api]}
      authorize_if {Scope, scope: "target:admin"}
    end

    policy action([:update]) do
      authorize_if {SystemActor, roles: [:coordinator]}
      authorize_if {Scope, scope: "target:admin"}
    end

    policy action([:destroy]) do
      authorize_if {SystemActor, roles: [:jobs]}
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:target_id]
    end

    update :update do
      primary? true

      accept [
        :branch_ttl,
        :held_ttl,
        :overlay_retention,
        :compensation_retention,
        :revert_window,
        :uncovered_changeset_verdict,
        :summary_values_allowed,
        :assertion_budget_s,
        :assertion_timeout_s,
        :impact_timeout_s,
        :heartbeat_lost_after,
        :merge_lease,
        :merge_stall_budget,
        :separate_approval
      ]
    end
  end

  def default_branch_ttl, do: Duration.new!(hour: 24)
  def default_overlay_retention, do: Duration.new!(day: 7)
  def default_compensation_retention, do: Duration.new!(day: 90)
  def default_heartbeat_lost_after, do: Duration.new!(minute: 5)
  def default_merge_lease, do: Duration.new!(minute: 5)
  def default_merge_stall_budget, do: Duration.new!(hour: 1)
end

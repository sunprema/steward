defmodule Steward.Core.Reviews.ReviewFeature do
  @moduledoc """
  Doc 12 §2.3 `review_features` — written by `record_review_features/1`
  (doc 06 §5.6) from data already in the control plane; read only by the
  M2+ suggestion job. No row data. 1:1 with `Review`, keyed by `review_id`.
  """
  use Ash.Resource,
    domain: Steward.Core.Reviews,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "review_features"
    repo Steward.Repo

    custom_statements do
      statement :validate_boundary_json_fn do
        up Steward.Core.Audit.BoundaryJson.create_function_sql()
        down Steward.Core.Audit.BoundaryJson.drop_function_sql()
      end

      statement :validate_boundary_json_row_counts do
        up Steward.Core.Audit.BoundaryJson.create_trigger_sql("review_features", "row_counts")
        down Steward.Core.Audit.BoundaryJson.drop_trigger_sql("review_features", "row_counts")
      end

      statement :validate_boundary_json_summary_stats do
        up Steward.Core.Audit.BoundaryJson.create_trigger_sql("review_features", "summary_stats")
        down Steward.Core.Audit.BoundaryJson.drop_trigger_sql("review_features", "summary_stats")
      end

      statement :validate_boundary_json_impact do
        up Steward.Core.Audit.BoundaryJson.create_trigger_sql("review_features", "impact")
        down Steward.Core.Audit.BoundaryJson.drop_trigger_sql("review_features", "impact")
      end

      statement :raise_immutable_fn do
        up Steward.Core.Audit.AppendOnly.raise_immutable_function_sql()
        down Steward.Core.Audit.AppendOnly.drop_raise_immutable_function_sql()
      end

      statement :review_features_immutable_trigger do
        up Steward.Core.Audit.AppendOnly.create_trigger_sql("review_features")
        down Steward.Core.Audit.AppendOnly.drop_trigger_sql("review_features")
      end

      statement :review_features_grants do
        up Steward.Core.Audit.AppendOnly.revoke_sql("review_features")
        down Steward.Core.Audit.AppendOnly.grant_sql("review_features")
      end
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    attribute :review_id, :uuid, primary_key?: true, allow_nil?: false
    attribute :org_id, :uuid, allow_nil?: false

    attribute :decision, Steward.Core.Types.ReviewDecision, allow_nil?: false
    attribute :allow_retry, :boolean, allow_nil?: false, default: false
    attribute :branch_principal_kind, Steward.Core.Types.PrincipalKind, allow_nil?: false
    attribute :tables, {:array, :string}, allow_nil?: false, default: []
    attribute :columns, {:array, :string}, allow_nil?: false, default: []
    attribute :row_counts, :map, allow_nil?: false, default: %{}
    attribute :summary_stats, :map, allow_nil?: false, default: %{}
    attribute :impact, :map, allow_nil?: false, default: %{}
    attribute :fired_assertion_ids, {:array, :uuid}, allow_nil?: false, default: []
    attribute :verdict_reason, Steward.Core.Types.VerdictReason, allow_nil?: false
    attribute :conflicts_count, :integer, allow_nil?: false, default: 0
    attribute :reversible, :string, allow_nil?: true
    attribute :proposed_dow, :integer, allow_nil?: false
    attribute :proposed_hour, :integer, allow_nil?: false
    attribute :held_seconds, :integer, allow_nil?: true
    attribute :decided_at, :utc_datetime_usec, allow_nil?: false

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :review, Steward.Core.Reviews.Review do
      source_attribute :review_id
      define_attribute? false
      allow_nil? false
      primary_key? true
    end

    belongs_to :changeset, Steward.Core.Branches.Changeset do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :target, Steward.Core.Targets.Target do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :reviewer_principal, Steward.Core.Targets.Principal do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :branch_principal, Steward.Core.Targets.Principal do
      allow_nil? false
      attribute_writable? true
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :review_id,
        :changeset_id,
        :target_id,
        :decision,
        :allow_retry,
        :reviewer_principal_id,
        :branch_principal_id,
        :branch_principal_kind,
        :tables,
        :columns,
        :row_counts,
        :summary_stats,
        :impact,
        :fired_assertion_ids,
        :verdict_reason,
        :conflicts_count,
        :reversible,
        :proposed_dow,
        :proposed_hour,
        :held_seconds,
        :decided_at
      ]
    end
  end
end

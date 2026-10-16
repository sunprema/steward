defmodule Steward.Core.Reviews.Review do
  @moduledoc "Doc 12 §2.2 `reviews` — permanent and attributed (doc 13 §6.4). Append-only."
  use Ash.Resource,
    domain: Steward.Core.Reviews,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "reviews"
    repo Steward.Repo

    references do
      reference :changeset, match_tenant?: true
      reference :branch, match_tenant?: true
      reference :reviewer_principal, match_tenant?: true
    end

    check_constraints do
      check_constraint :allow_retry, "retry_only_on_reject",
        check: "NOT allow_retry OR decision = 'rejected'"

      # Lift when doc 13 §12 schedules edit.
      check_constraint :decision, "edit_not_in_m0", check: "decision <> 'edited'"
    end

    custom_statements do
      statement :raise_immutable_fn do
        up Steward.Core.Audit.AppendOnly.raise_immutable_function_sql()
        down Steward.Core.Audit.AppendOnly.drop_raise_immutable_function_sql()
      end

      statement :reviews_immutable_trigger do
        up Steward.Core.Audit.AppendOnly.create_trigger_sql("reviews")
        down Steward.Core.Audit.AppendOnly.drop_trigger_sql("reviews")
      end

      statement :reviews_grants do
        up Steward.Core.Audit.AppendOnly.revoke_sql("reviews")
        down Steward.Core.Audit.AppendOnly.grant_sql("reviews")
      end
    end
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :decision, Steward.Core.Types.ReviewDecision, allow_nil?: false
    attribute :allow_retry, :boolean, allow_nil?: false, default: false
    attribute :note, :string, allow_nil?: true, constraints: [max_length: 4096]
    attribute :idempotency_key, :string, allow_nil?: false
    attribute :decided_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :changeset, Steward.Core.Branches.Changeset do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :branch, Steward.Core.Branches.Branch do
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
  end

  identities do
    identity :unique_changeset, [:changeset_id]
    identity :unique_idempotency_key, [:reviewer_principal_id, :idempotency_key]
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :changeset_id,
        :branch_id,
        :target_id,
        :reviewer_principal_id,
        :decision,
        :allow_retry,
        :note,
        :idempotency_key
      ]

      change {Steward.Core.Audit.AppendEvent,
              type: "review.recorded",
              aggregate_type: "review",
              payload: &__MODULE__.recorded_payload/2}
    end
  end

  def recorded_payload(_changeset, record) do
    %{
      changeset_id: record.changeset_id,
      decision: record.decision,
      allow_retry: record.allow_retry,
      reviewer_principal_id: record.reviewer_principal_id
    }
  end
end

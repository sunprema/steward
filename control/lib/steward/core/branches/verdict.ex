defmodule Steward.Core.Branches.Verdict do
  @moduledoc "Doc 12 §2.2 `verdicts` — exactly one per changeset (doc 13 invariant 4). Append-only."
  alias Steward.Core.Authz.Checks.{ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Branches,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "verdicts"
    repo Steward.Repo

    references do
      reference :changeset, match_tenant?: true
    end

    check_constraints do
      check_constraint :policy_outcome, "floor_only_raises",
        check: "policy_outcome = outcome OR (reason = 'revert_conflict' AND outcome = 'hold')"
    end

    custom_statements do
      statement :raise_immutable_fn do
        up Steward.Core.Audit.AppendOnly.raise_immutable_function_sql()
        down Steward.Core.Audit.AppendOnly.drop_raise_immutable_function_sql()
      end

      statement :verdicts_immutable_trigger do
        up Steward.Core.Audit.AppendOnly.create_trigger_sql("verdicts")
        down Steward.Core.Audit.AppendOnly.drop_trigger_sql("verdicts")
      end

      statement :verdicts_grants do
        up Steward.Core.Audit.AppendOnly.revoke_sql("verdicts")
        down Steward.Core.Audit.AppendOnly.grant_sql("verdicts")
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

    attribute :outcome, Steward.Core.Types.VerdictOutcome, allow_nil?: false
    attribute :reason, Steward.Core.Types.VerdictReason, allow_nil?: false
    attribute :policy_outcome, Steward.Core.Types.VerdictOutcome, allow_nil?: false
    attribute :policy_version_ids, {:array, :uuid}, allow_nil?: false, default: []
    attribute :evaluated_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0
    attribute :control_plane_ms, :integer, allow_nil?: false
    attribute :data_plane_ms, :integer, allow_nil?: false

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :changeset, Steward.Core.Branches.Changeset do
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_changeset, [:changeset_id]
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: "changeset:read", target: {:via, [:changeset]}}
    end

    policy action([:create]) do
      authorize_if {SystemActor, roles: [:coordinator]}
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :changeset_id,
        :outcome,
        :reason,
        :policy_outcome,
        :policy_version_ids,
        :control_plane_ms,
        :data_plane_ms
      ]
    end
  end
end

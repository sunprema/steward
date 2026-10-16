defmodule Steward.Core.Branches.Revert do
  @moduledoc """
  Doc 12 §2.3 `reverts`. Partial uniques enforce "at most one in-flight
  revert per merge" and "at most one merged revert per merge" (doc 02 §3,
  doc 13 invariant 14).
  """
  alias Steward.Core.Authz.Checks.{ActsAs, Scope, ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Branches,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "reverts"
    repo Steward.Repo

    identity_wheres_to_sql unique_in_flight_per_merge: "outcome IS NULL",
                           unique_merged_per_merge: "outcome = 'merged'"
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    # merged | rejected | abandoned | nil (in flight); CHECK added via check_constraints below.
    attribute :outcome, :string, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :target, Steward.Core.Targets.Target do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :merge, Steward.Core.Branches.Merge do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :revert_branch, Steward.Core.Branches.Branch do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :requested_by_principal, Steward.Core.Targets.Principal do
      source_attribute :requested_by
      allow_nil? false
      attribute_writable? true
    end
  end

  identities do
    identity :unique_revert_branch, [:revert_branch_id]
    identity :unique_in_flight_per_merge, [:merge_id], where: expr(is_nil(outcome))
    identity :unique_merged_per_merge, [:merge_id], where: expr(outcome == "merged")
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: "changeset:read"}
    end

    # Initiating a revert needs `merge:revert` on the merge's own target (doc 13 §6.6); the
    # target is read from the merge, not trusted from the request.
    policy action([:create]) do
      authorize_if {SystemActor, roles: [:coordinator]}
      forbid_unless {ActsAs, attribute: :requested_by}
      authorize_if {Scope, scope: "merge:revert", target: {__MODULE__, :authz_target_id}}
    end

    policy action([:record_outcome]) do
      authorize_if {SystemActor, roles: [:coordinator]}
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:target_id, :merge_id, :revert_branch_id, :requested_by]
    end

    update :record_outcome do
      accept [:outcome]
    end
  end

  @doc false
  def authz_target_id(subject),
    do: Steward.Core.Authz.Subject.target_via(subject, :merge_id, Steward.Core.Branches.Merge)
end

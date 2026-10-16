defmodule Steward.Core.Audit.WebhookDelivery do
  @moduledoc "Doc 12 §2.3 `webhook_deliveries`. 7-day retention via `DeliveryPurge` (E12, out of scope here)."
  alias Steward.Core.Authz.Checks.{ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Audit,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "webhook_deliveries"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    integer_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :attempt, :integer, allow_nil?: false, default: 1
    # pending | delivered | failed | dead (doc 12 §2.3); CHECK added by hand migration.
    attribute :status, :string, allow_nil?: false, default: "pending"

    attribute :response_code, :integer, allow_nil?: true
    attribute :next_attempt_at, :utc_datetime_usec, allow_nil?: true
    attribute :delivered_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :webhook, Steward.Core.Audit.Webhook do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :event, Steward.Core.Audit.Event do
      allow_nil? false
      attribute_type :integer
      attribute_writable? true
    end
  end

  identities do
    identity :unique_attempt, [:webhook_id, :event_id, :attempt]
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: "webhook:admin", target: :org}
    end

    policy action([:create, :update, :destroy]) do
      authorize_if {SystemActor, roles: [:jobs]}
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:webhook_id, :event_id, :attempt, :status, :next_attempt_at]
    end

    update :update do
      primary? true
      accept [:status, :response_code, :next_attempt_at, :delivered_at, :attempt]
    end
  end
end

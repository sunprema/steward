defmodule Steward.Core.Audit.Webhook do
  @moduledoc """
  Doc 12 §2.3 `webhooks` — a delivery destination for `Steward.Core.Audit.Event`
  rows (doc 07 §5.7's `NotifyPrincipal` consumer, doc 10 §6). `target_id` is
  deliberately a plain attribute, not an Ash relationship: doc 12 shows no
  explicit foreign key for it, and declaring one would create a cycle with
  `Steward.Core.Targets` (which itself depends on `Audit` for `AppendEvent`).
  """
  alias Steward.Core.Authz.Checks.{ActsAs, Scope, ScopedRead, SystemActor}

  use Ash.Resource,
    domain: Steward.Core.Audit,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "webhooks"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :target_id, :uuid, allow_nil?: true
    attribute :url, :string, allow_nil?: false, constraints: [match: ~r{^https://}]
    attribute :secret_ciphertext, :binary, allow_nil?: false, sensitive?: true
    attribute :event_types, {:array, :string}, allow_nil?: false, default: []
    attribute :enabled, :boolean, allow_nil?: false, default: true
    attribute :created_by, :uuid, allow_nil?: false

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  policies do
    policy action_type(:read) do
      authorize_if {SystemActor, roles: :any}
      authorize_if {ScopedRead, scope: "webhook:admin", target: :org}
    end

    policy action([:create]) do
      forbid_unless {ActsAs, attribute: :created_by}
      authorize_if {Scope, scope: "webhook:admin", target: :org}
    end

    policy action([:update, :destroy]) do
      authorize_if {Scope, scope: "webhook:admin", target: :org}
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:target_id, :url, :secret_ciphertext, :event_types, :created_by]
    end

    update :update do
      primary? true
      accept [:url, :secret_ciphertext, :event_types, :enabled]
    end
  end
end

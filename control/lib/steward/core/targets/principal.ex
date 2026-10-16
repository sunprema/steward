defmodule Steward.Core.Targets.Principal do
  @moduledoc """
  Doc 12 §2.3 `principals`. The policy-scope form `agent:pricing-bot` is
  `kind <> ":" <> slug` (doc 06 §4.2).
  """
  use Ash.Resource,
    domain: Steward.Core.Targets,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "principals"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :org_id, :uuid, allow_nil?: false

    attribute :kind, Steward.Core.Types.PrincipalKind, allow_nil?: false
    attribute :slug, :string, allow_nil?: false
    attribute :display_name, :string, allow_nil?: false
    attribute :org_admin, :boolean, allow_nil?: false, default: false
    attribute :email, :string, allow_nil?: true
    attribute :sso_subject, :string, allow_nil?: true
    attribute :disabled_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_kind_slug, [:kind, :slug]
    identity :unique_org_id, [:id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:kind, :slug, :display_name, :org_admin, :email, :sso_subject]
    end

    update :update do
      primary? true
      accept [:display_name, :org_admin, :email, :sso_subject, :disabled_at]
    end
  end

  def scope_id(%{kind: kind, slug: slug}), do: "#{kind}:#{slug}"
end

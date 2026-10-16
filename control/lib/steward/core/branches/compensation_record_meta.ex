defmodule Steward.Core.Branches.CompensationRecordMeta do
  @moduledoc """
  Doc 12 §2.3 `compensation_records_meta` — a metadata mirror of the doc 09
  index, written from heartbeat `compensation_status`; never segments,
  keys, or images. 1:1 with `Merge`, keyed by `merge_id`.
  """
  use Ash.Resource,
    domain: Steward.Core.Branches,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "compensation_records_meta"
    repo Steward.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  attributes do
    attribute :merge_id, :uuid, primary_key?: true, allow_nil?: false
    attribute :org_id, :uuid, allow_nil?: false

    attribute :status, Steward.Core.Types.CompensationStatus, allow_nil?: false
    attribute :retention_until, :utc_datetime_usec, allow_nil?: true
    attribute :legal_hold, :boolean, allow_nil?: false, default: false
    attribute :row_count, :integer, allow_nil?: true
    attribute :bytes, :integer, allow_nil?: true
    attribute :partial_keys_count, :integer, allow_nil?: true
    attribute :header_sha256, :binary, allow_nil?: true
    attribute :persisted_at, :utc_datetime_usec, allow_nil?: true
    attribute :body_deleted_at, :utc_datetime_usec, allow_nil?: true
    attribute :last_reported_at, :utc_datetime_usec, allow_nil?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :merge, Steward.Core.Branches.Merge do
      source_attribute :merge_id
      define_attribute? false
      allow_nil? false
      primary_key? true
    end

    belongs_to :target, Steward.Core.Targets.Target do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :branch, Steward.Core.Branches.Branch do
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :reserved_by_branch, Steward.Core.Branches.Branch do
      attribute_writable? true
    end

    belongs_to :consumed_by_branch, Steward.Core.Branches.Branch do
      attribute_writable? true
    end
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :merge_id,
        :target_id,
        :branch_id,
        :status,
        :row_count,
        :bytes,
        :partial_keys_count,
        :header_sha256,
        :persisted_at,
        :retention_until
      ]
    end

    update :update do
      primary? true

      accept [
        :status,
        :reserved_by_branch_id,
        :consumed_by_branch_id,
        :retention_until,
        :legal_hold,
        :body_deleted_at,
        :last_reported_at
      ]
    end
  end
end

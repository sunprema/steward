defmodule Steward.Plane.V1.BranchState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "steward.plane.v1.BranchState",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :BRANCH_STATE_UNSPECIFIED, 0
  field :BRANCH_STATE_OPEN, 1
  field :BRANCH_STATE_PROPOSED, 2
  field :BRANCH_STATE_MERGING, 3
  field :BRANCH_STATE_MERGED, 4
  field :BRANCH_STATE_REJECTED, 5
  field :BRANCH_STATE_ABANDONED, 6
  field :BRANCH_STATE_CLOSED, 7
end

defmodule Steward.Plane.V1.ChangesetState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "steward.plane.v1.ChangesetState",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :CHANGESET_STATE_UNSPECIFIED, 0
  field :CHANGESET_STATE_COMPUTING, 1
  field :CHANGESET_STATE_EVALUATED, 2
  field :CHANGESET_STATE_SUPERSEDED, 3
end

defmodule Steward.Plane.V1.VerdictOutcome do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "steward.plane.v1.VerdictOutcome",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :VERDICT_OUTCOME_UNSPECIFIED, 0
  field :VERDICT_OUTCOME_AUTO_MERGE, 1
  field :VERDICT_OUTCOME_HOLD, 2
  field :VERDICT_OUTCOME_BLOCK, 3
end

defmodule Steward.Plane.V1.VerdictReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "steward.plane.v1.VerdictReason",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :VERDICT_REASON_UNSPECIFIED, 0
  field :VERDICT_REASON_POLICIES, 1
  field :VERDICT_REASON_POLICY_ERROR, 2
  field :VERDICT_REASON_NO_POLICY_COVERAGE, 3
  field :VERDICT_REASON_REVERT_CONFLICT, 4
end

defmodule Steward.Plane.V1.LifecycleReason do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "steward.plane.v1.LifecycleReason",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :LIFECYCLE_REASON_UNSPECIFIED, 0
  field :LIFECYCLE_REASON_SNAPSHOT_LOST, 1
  field :LIFECYCLE_REASON_OVERLAY_LOST, 2
  field :LIFECYCLE_REASON_STALE_BASE, 3
  field :LIFECYCLE_REASON_TTL_EXPIRED, 4
  field :LIFECYCLE_REASON_REJECT_WITH_RETRY, 5
  field :LIFECYCLE_REASON_COMPUTE_FAILED, 6
  field :LIFECYCLE_REASON_DATA_PLANE_UNREACHABLE, 7
  field :LIFECYCLE_REASON_COMPENSATION_FAILED, 8
  field :LIFECYCLE_REASON_ADAPTER_UNAVAILABLE, 9
  field :LIFECYCLE_REASON_WITHDRAWN, 10
  field :LIFECYCLE_REASON_REEVALUATED, 11
  field :LIFECYCLE_REASON_NEW_CHANGESET, 12
  field :LIFECYCLE_REASON_VERDICT_BLOCK, 13
  field :LIFECYCLE_REASON_REVIEW_REJECTED, 14
  field :LIFECYCLE_REASON_REVIEW_APPROVED, 15
  field :LIFECYCLE_REASON_VERDICT_AUTO_MERGE, 16
  field :LIFECYCLE_REASON_ABANDONED_BY_PRINCIPAL, 17
  field :LIFECYCLE_REASON_MERGE_APPLIED, 18
  field :LIFECYCLE_REASON_RETENTION_ELAPSED, 19
end

defmodule Steward.Plane.V1.BelievedState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "steward.plane.v1.BelievedState",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :BELIEVED_UNSPECIFIED, 0
  field :OPEN, 1
  field :PROPOSED, 2
  field :MERGING, 3
  field :DONE, 4
  field :DEAD, 5
end

defmodule Steward.Plane.V1.AuthoritativeState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "steward.plane.v1.AuthoritativeState",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :AUTH_UNSPECIFIED, 0
  field :UNKNOWN, 1
  field :AUTH_OPEN, 2
  field :AUTH_PROPOSED, 3
  field :AUTH_MERGING, 4
  field :MERGED, 5
  field :REJECTED, 6
  field :ABANDONED, 7
  field :CLOSED, 8
end

defmodule Steward.Plane.V1.CompensationRecordStatus do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "steward.plane.v1.CompensationRecordStatus",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :CRS_UNSPECIFIED, 0
  field :COMPLETE, 1
  field :PARTIAL, 2
  field :CONSUMED, 3
  field :EXPIRED, 4
  field :CORRUPT, 5
end

defmodule Steward.Plane.V1.RevertOutcomeKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "steward.plane.v1.RevertOutcomeKind",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :RO_UNSPECIFIED, 0
  field :RO_MERGED, 1
  field :RO_REJECTED, 2
  field :RO_ABANDONED, 3
end

defmodule Steward.Plane.V1.EnrolRequest do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.EnrolRequest",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :enrolment_token, 1, type: :string, json_name: "enrolmentToken"
  field :csr, 2, type: :bytes
  field :export_public_key, 3, type: :bytes, json_name: "exportPublicKey"
  field :chart_version, 4, type: :string, json_name: "chartVersion"
  field :contracts_version, 5, type: :string, json_name: "contractsVersion"
end

defmodule Steward.Plane.V1.EnrolResponse do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.EnrolResponse",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :certificate, 1, type: :bytes
  field :ca_chain, 2, type: :bytes, json_name: "caChain"
  field :grant_public_keys, 3, repeated: true, type: :bytes, json_name: "grantPublicKeys"
  field :data_plane_id, 4, type: :string, json_name: "dataPlaneId"
end

defmodule Steward.Plane.V1.DataPlaneMessage do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.DataPlaneMessage",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:body, 0)

  field :data_plane_id, 1, type: :string, json_name: "dataPlaneId"
  field :heartbeat, 2, type: Steward.Plane.V1.Heartbeat, oneof: 0

  field :changeset_report, 3,
    type: Steward.Plane.V1.ChangesetReport,
    json_name: "changesetReport",
    oneof: 0

  field :instruction_result, 4,
    type: Steward.Plane.V1.InstructionResult,
    json_name: "instructionResult",
    oneof: 0

  field :merge_outcome, 5,
    type: Steward.Plane.V1.MergeOutcome,
    json_name: "mergeOutcome",
    oneof: 0

  field :audit_event, 6,
    type: Steward.Plane.V1.DataPlaneAuditEvent,
    json_name: "auditEvent",
    oneof: 0

  field :version, 7, type: :string
end

defmodule Steward.Plane.V1.ControlPlaneMessage do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.ControlPlaneMessage",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:body, 0)

  field :heartbeat_reply, 1,
    type: Steward.Plane.V1.HeartbeatReply,
    json_name: "heartbeatReply",
    oneof: 0

  field :instruction, 2, type: Steward.Plane.V1.Instruction, oneof: 0
end

defmodule Steward.Plane.V1.Heartbeat do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.Heartbeat",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :branch_id, 1, type: :string, json_name: "branchId"
  field :overlay_id, 2, type: :string, json_name: "overlayId"

  field :believed_state, 3,
    type: Steward.Plane.V1.BelievedState,
    json_name: "believedState",
    enum: true

  field :overlay_size_bytes, 4, type: :uint64, json_name: "overlaySizeBytes"
  field :overlay_rows, 5, type: :uint64, json_name: "overlayRows"

  field :merge_progress, 6,
    proto3_optional: true,
    type: Steward.Plane.V1.MergeProgress,
    json_name: "mergeProgress"

  field :evidence_gap, 7, proto3_optional: true, type: :uint32, json_name: "evidenceGap"

  field :compensation_status, 8,
    proto3_optional: true,
    type: Steward.Plane.V1.CompensationStatus,
    json_name: "compensationStatus"

  field :revert_outcome, 9,
    proto3_optional: true,
    type: Steward.Plane.V1.RevertOutcome,
    json_name: "revertOutcome"

  field :retention_ack, 10,
    proto3_optional: true,
    type: Steward.Plane.V1.RetentionAck,
    json_name: "retentionAck"

  field :freeze_acknowledged, 11, type: :bool, json_name: "freezeAcknowledged"
  field :base_snapshot_gone, 12, type: :bool, json_name: "baseSnapshotGone"
  field :sent_at, 13, type: Google.Protobuf.Timestamp, json_name: "sentAt"
end

defmodule Steward.Plane.V1.MergeProgress do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.MergeProgress",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :merge_id, 1, type: :string, json_name: "mergeId"
  field :rows_confirmed, 2, type: :uint64, json_name: "rowsConfirmed"
  field :rows_total, 3, type: :uint64, json_name: "rowsTotal"
  field :complete, 4, type: :bool
  field :compensation_persisted, 5, type: :bool, json_name: "compensationPersisted"
  field :last_error_code, 6, proto3_optional: true, type: :string, json_name: "lastErrorCode"

  field :retry_after, 7,
    proto3_optional: true,
    type: Google.Protobuf.Timestamp,
    json_name: "retryAfter"
end

defmodule Steward.Plane.V1.CompensationStatus do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.CompensationStatus",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :merge_id, 1, type: :string, json_name: "mergeId"
  field :status, 2, type: Steward.Plane.V1.CompensationRecordStatus, enum: true
  field :merge_applied, 3, type: :bool, json_name: "mergeApplied"
  field :header_hash, 4, type: :string, json_name: "headerHash"
end

defmodule Steward.Plane.V1.RevertOutcome do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.RevertOutcome",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :revert_of_merge_id, 1, type: :string, json_name: "revertOfMergeId"
  field :outcome, 2, type: Steward.Plane.V1.RevertOutcomeKind, enum: true
end

defmodule Steward.Plane.V1.RetentionAck do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.RetentionAck",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :merge_id, 1, type: :string, json_name: "mergeId"
  field :retention_until, 2, type: Google.Protobuf.Timestamp, json_name: "retentionUntil"
  field :legal_hold, 3, type: :bool, json_name: "legalHold"
end

defmodule Steward.Plane.V1.HeartbeatReply do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.HeartbeatReply",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :branch_id, 1, type: :string, json_name: "branchId"
  field :overlay_id, 2, type: :string, json_name: "overlayId"

  field :authoritative_state, 3,
    type: Steward.Plane.V1.AuthoritativeState,
    json_name: "authoritativeState",
    enum: true

  field :lease_renewed, 4, type: :bool, json_name: "leaseRenewed"
  field :freeze, 5, type: :bool

  field :retention_until, 6,
    proto3_optional: true,
    type: Google.Protobuf.Timestamp,
    json_name: "retentionUntil"

  field :legal_hold, 7, proto3_optional: true, type: :bool, json_name: "legalHold"
  field :stale, 8, type: :bool
end

defmodule Steward.Plane.V1.ChangesetReport do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.ChangesetReport",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :changeset_id, 1, type: :string, json_name: "changesetId"
  field :branch_id, 2, type: :string, json_name: "branchId"
  field :overlay_id, 3, type: :string, json_name: "overlayId"
  field :summary, 4, type: Steward.Plane.V1.Summary
  field :impact, 5, repeated: true, type: Steward.Plane.V1.ImpactMetric

  field :assertion_results, 6,
    repeated: true,
    type: Steward.Plane.V1.AssertionResult,
    json_name: "assertionResults"

  field :evidence_refs, 7,
    repeated: true,
    type: Steward.Plane.V1.EvidenceRef,
    json_name: "evidenceRefs"

  field :row_delta_digest, 8, type: :bytes, json_name: "rowDeltaDigest"
  field :reversible, 9, type: :string
  field :conflicts_count, 10, type: :uint64, json_name: "conflictsCount"

  field :touches_revertable_merges, 11,
    repeated: true,
    type: :string,
    json_name: "touchesRevertableMerges"

  field :evidence_query_count, 12, type: :uint64, json_name: "evidenceQueryCount"
  field :evidence_tables_read, 13, repeated: true, type: :string, json_name: "evidenceTablesRead"
  field :error, 14, proto3_optional: true, type: Steward.Plane.V1.ComputeError
  field :trace_context, 15, type: :string, json_name: "traceContext"
end

defmodule Steward.Plane.V1.Summary do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.Summary",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :truncated, 1, type: :bool
  field :tables, 2, repeated: true, type: Steward.Plane.V1.TableSummary
  field :columns, 3, repeated: true, type: Steward.Plane.V1.ColumnSummary
  field :staleness_check, 4, proto3_optional: true, type: :string, json_name: "stalenessCheck"
  field :conflicts_ref, 5, proto3_optional: true, type: :string, json_name: "conflictsRef"
  field :partial_keys_count, 6, type: :uint64, json_name: "partialKeysCount"
end

defmodule Steward.Plane.V1.TableSummary do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.TableSummary",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :table_name, 1, type: :string, json_name: "tableName"
  field :inserts, 2, type: :uint64
  field :updates, 3, type: :uint64
  field :deletes, 4, type: :uint64
  field :noop_updates, 5, type: :uint64, json_name: "noopUpdates"
  field :invalid_before_images, 6, type: :uint64, json_name: "invalidBeforeImages"
end

defmodule Steward.Plane.V1.ColumnSummary do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.ColumnSummary",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :table_name, 1, type: :string, json_name: "tableName"
  field :column_name, 2, type: :string, json_name: "columnName"
  field :changed_count, 3, type: :uint64, json_name: "changedCount"
  field :null_delta, 4, type: :int64, json_name: "nullDelta"
  field :numeric_delta_min, 5, proto3_optional: true, type: :double, json_name: "numericDeltaMin"
  field :numeric_delta_max, 6, proto3_optional: true, type: :double, json_name: "numericDeltaMax"

  field :numeric_delta_median, 7,
    proto3_optional: true,
    type: :double,
    json_name: "numericDeltaMedian"

  field :numeric_pct_median, 8,
    proto3_optional: true,
    type: :double,
    json_name: "numericPctMedian"

  field :distinct_before, 9, type: :uint64, json_name: "distinctBefore"
  field :distinct_after, 10, type: :uint64, json_name: "distinctAfter"

  field :distinct_values, 11,
    repeated: true,
    type: Steward.Plane.V1.DistinctValue,
    json_name: "distinctValues"
end

defmodule Steward.Plane.V1.DistinctValue do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.DistinctValue",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :value, 1, type: :string
  field :count_before, 2, type: :uint64, json_name: "countBefore"
  field :count_after, 3, type: :uint64, json_name: "countAfter"
end

defmodule Steward.Plane.V1.ImpactMetric do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.ImpactMetric",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :name, 1, type: :string
  field :value, 2, proto3_optional: true, type: :double
  field :error, 3, proto3_optional: true, type: :string
end

defmodule Steward.Plane.V1.AssertionResult do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.AssertionResult",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :policy_id, 1, type: :string, json_name: "policyId"
  field :assertion_id, 2, type: :string, json_name: "assertionId"
  field :status, 3, type: :string
  field :count, 4, type: :uint64
  field :count_capped, 5, type: :bool, json_name: "countCapped"
  field :denominator, 6, proto3_optional: true, type: :uint64
  field :sample_ref, 7, type: :string, json_name: "sampleRef"
  field :error_code, 8, proto3_optional: true, type: :string, json_name: "errorCode"
  field :duration_ms, 9, type: :uint32, json_name: "durationMs"
end

defmodule Steward.Plane.V1.EvidenceRef do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.EvidenceRef",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :path, 1, type: :string
  field :digest, 2, type: :bytes
end

defmodule Steward.Plane.V1.ComputeError do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.ComputeError",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :code, 1, type: :string
  field :safe_message, 2, type: :string, json_name: "safeMessage"
  field :retryable, 3, type: :bool
end

defmodule Steward.Plane.V1.Instruction do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.Instruction",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:body, 0)

  field :instruction_id, 1, type: :string, json_name: "instructionId"

  field :initialise_overlay, 2,
    type: Steward.Plane.V1.InitialiseOverlay,
    json_name: "initialiseOverlay",
    oneof: 0

  field :routing_upsert, 3,
    type: Steward.Plane.V1.RoutingUpsert,
    json_name: "routingUpsert",
    oneof: 0

  field :freeze_writes, 4,
    type: Steward.Plane.V1.FreezeWrites,
    json_name: "freezeWrites",
    oneof: 0

  field :compute_changeset, 5,
    type: Steward.Plane.V1.ComputeChangeset,
    json_name: "computeChangeset",
    oneof: 0

  field :run_assertions, 6,
    type: Steward.Plane.V1.RunAssertions,
    json_name: "runAssertions",
    oneof: 0

  field :merge, 7, type: Steward.Plane.V1.Merge, oneof: 0

  field :close_overlay, 8,
    type: Steward.Plane.V1.CloseOverlay,
    json_name: "closeOverlay",
    oneof: 0

  field :set_retention, 9,
    type: Steward.Plane.V1.SetRetention,
    json_name: "setRetention",
    oneof: 0

  field :set_legal_hold, 10,
    type: Steward.Plane.V1.SetLegalHold,
    json_name: "setLegalHold",
    oneof: 0

  field :register_target, 11,
    type: Steward.Plane.V1.RegisterTarget,
    json_name: "registerTarget",
    oneof: 0

  field :trace_context, 12, type: :string, json_name: "traceContext"
end

defmodule Steward.Plane.V1.InitialiseOverlay do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.InitialiseOverlay",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :branch_id, 1, type: :string, json_name: "branchId"
  field :target_id, 2, type: :string, json_name: "targetId"
  field :revert_of_merge_id, 3, proto3_optional: true, type: :string, json_name: "revertOfMergeId"
  field :copy_overlay_from, 4, proto3_optional: true, type: :string, json_name: "copyOverlayFrom"
end

defmodule Steward.Plane.V1.RoutingUpsert do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.RoutingUpsert",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :branch_id, 1, type: :string, json_name: "branchId"
  field :overlay_id, 2, type: :string, json_name: "overlayId"
  field :target_id, 3, type: :string, json_name: "targetId"
  field :base_snapshot_ref, 4, type: :string, json_name: "baseSnapshotRef"
  field :credential_ref, 5, type: :string, json_name: "credentialRef"
  field :state, 6, type: Steward.Plane.V1.AuthoritativeState, enum: true
  field :policy_version_set_hash, 7, type: :string, json_name: "policyVersionSetHash"
  field :principal_id, 8, type: :string, json_name: "principalId"
  field :api_keys, 9, repeated: true, type: Steward.Plane.V1.ApiKeyEntry, json_name: "apiKeys"
end

defmodule Steward.Plane.V1.ApiKeyEntry do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.ApiKeyEntry",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :key_hash, 1, type: :bytes, json_name: "keyHash"
  field :principal_id, 2, type: :string, json_name: "principalId"
  field :revoked, 3, type: :bool
end

defmodule Steward.Plane.V1.FreezeWrites do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.FreezeWrites",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :branch_id, 1, type: :string, json_name: "branchId"
  field :overlay_id, 2, type: :string, json_name: "overlayId"
  field :unfreeze, 3, type: :bool
end

defmodule Steward.Plane.V1.ComputeChangeset do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.ComputeChangeset",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :changeset_id, 1, type: :string, json_name: "changesetId"
  field :branch_id, 2, type: :string, json_name: "branchId"
  field :overlay_id, 3, type: :string, json_name: "overlayId"
  field :base_snapshot_ref, 4, type: :string, json_name: "baseSnapshotRef"

  field :impact_queries, 5,
    repeated: true,
    type: Steward.Plane.V1.ImpactQuery,
    json_name: "impactQueries"

  field :assertions, 6, repeated: true, type: Steward.Plane.V1.Assertion
  field :assertion_budget_s, 7, type: :uint32, json_name: "assertionBudgetS"
  field :revert_of_merge_id, 8, proto3_optional: true, type: :string, json_name: "revertOfMergeId"

  field :conflicts_from_merge_id, 9,
    proto3_optional: true,
    type: :string,
    json_name: "conflictsFromMergeId"
end

defmodule Steward.Plane.V1.RunAssertions do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.RunAssertions",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :changeset_id, 1, type: :string, json_name: "changesetId"
  field :source_changeset_id, 2, type: :string, json_name: "sourceChangesetId"
  field :assertions, 3, repeated: true, type: Steward.Plane.V1.Assertion
  field :assertion_budget_s, 4, type: :uint32, json_name: "assertionBudgetS"
end

defmodule Steward.Plane.V1.ImpactQuery do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.ImpactQuery",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :id, 1, type: :string
  field :name, 2, type: :string
  field :sql, 3, type: :string
  field :timeout_s, 4, type: :uint32, json_name: "timeoutS"
end

defmodule Steward.Plane.V1.Assertion do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.Assertion",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :policy_id, 1, type: :string, json_name: "policyId"
  field :policy_version_id, 2, type: :string, json_name: "policyVersionId"
  field :assertion_id, 3, type: :string, json_name: "assertionId"
  field :sql, 4, type: :string
  field :expect_json, 5, type: :string, json_name: "expectJson"
  field :timeout_s, 6, type: :uint32, json_name: "timeoutS"
end

defmodule Steward.Plane.V1.Merge do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.Merge",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :merge_id, 1, type: :string, json_name: "mergeId"
  field :changeset_id, 2, type: :string, json_name: "changesetId"
  field :branch_id, 3, type: :string, json_name: "branchId"
  field :base_snapshot_ref, 4, type: :string, json_name: "baseSnapshotRef"
  field :policy_version_ids, 5, repeated: true, type: :string, json_name: "policyVersionIds"
  field :retention_until, 6, type: Google.Protobuf.Timestamp, json_name: "retentionUntil"
  field :legal_hold, 7, type: :bool, json_name: "legalHold"
end

defmodule Steward.Plane.V1.CloseOverlay do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.CloseOverlay",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :branch_id, 1, type: :string, json_name: "branchId"
  field :overlay_id, 2, type: :string, json_name: "overlayId"
end

defmodule Steward.Plane.V1.SetRetention do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.SetRetention",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :merge_id, 1, type: :string, json_name: "mergeId"
  field :retention_until, 2, type: Google.Protobuf.Timestamp, json_name: "retentionUntil"
end

defmodule Steward.Plane.V1.SetLegalHold do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.SetLegalHold",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :merge_id, 1, proto3_optional: true, type: :string, json_name: "mergeId"
  field :target_id, 2, proto3_optional: true, type: :string, json_name: "targetId"
  field :legal_hold, 3, type: :bool, json_name: "legalHold"
end

defmodule Steward.Plane.V1.RegisterTarget do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.RegisterTarget",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :target_id, 1, type: :string, json_name: "targetId"
  field :kind, 2, type: :string
  field :credential_ref, 3, type: :string, json_name: "credentialRef"
end

defmodule Steward.Plane.V1.InstructionResult do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.InstructionResult",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  oneof(:body, 0)

  field :instruction_id, 1, type: :string, json_name: "instructionId"
  field :ok, 2, type: :bool
  field :error_code, 3, proto3_optional: true, type: :string, json_name: "errorCode"
  field :safe_message, 4, proto3_optional: true, type: :string, json_name: "safeMessage"

  field :overlay_initialised, 5,
    type: Steward.Plane.V1.OverlayInitialised,
    json_name: "overlayInitialised",
    oneof: 0

  field :target_description, 6,
    type: Steward.Plane.V1.TargetDescription,
    json_name: "targetDescription",
    oneof: 0

  field :trace_context, 7, type: :string, json_name: "traceContext"
end

defmodule Steward.Plane.V1.OverlayInitialised do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.OverlayInitialised",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :overlay_id, 1, type: :string, json_name: "overlayId"
  field :base_snapshot_ref, 2, type: :string, json_name: "baseSnapshotRef"
  field :fidelity, 3, type: :string
  field :opened_at, 4, type: Google.Protobuf.Timestamp, json_name: "openedAt"
end

defmodule Steward.Plane.V1.TargetDescription do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.TargetDescription",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :target_id, 1, type: :string, json_name: "targetId"
  field :fidelity, 2, type: :string
  field :schema_json, 3, type: :string, json_name: "schemaJson"
  field :reversible_tables, 4, repeated: true, type: :string, json_name: "reversibleTables"
  field :adapter_version, 5, proto3_optional: true, type: :string, json_name: "adapterVersion"
  field :described_at, 6, type: Google.Protobuf.Timestamp, json_name: "describedAt"
end

defmodule Steward.Plane.V1.MergeOutcome do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.MergeOutcome",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :merge_id, 1, type: :string, json_name: "mergeId"
  field :status, 2, type: :string
  field :failure_reason, 3, proto3_optional: true, type: :string, json_name: "failureReason"
  field :compensation_persisted, 4, type: :bool, json_name: "compensationPersisted"
  field :compensation, 5, proto3_optional: true, type: Steward.Plane.V1.CompensationStatus
  field :trace_context, 6, type: :string, json_name: "traceContext"
  field :rows_applied, 7, type: :uint64, json_name: "rowsApplied"
  field :duration_ms, 8, type: :uint64, json_name: "durationMs"
end

defmodule Steward.Plane.V1.DataPlaneAuditEvent do
  @moduledoc false

  use Protobuf,
    full_name: "steward.plane.v1.DataPlaneAuditEvent",
    protoc_gen_elixir_version: "0.17.1",
    syntax: :proto3

  field :merge_id, 1, type: :string, json_name: "mergeId"
  field :action, 2, type: :string
  field :principal_id, 3, type: :string, json_name: "principalId"
  field :grant_jti, 4, type: :string, json_name: "grantJti"
  field :at, 5, type: Google.Protobuf.Timestamp
  field :changeset_id, 6, type: :string, json_name: "changesetId"
  field :trace_context, 7, type: :string, json_name: "traceContext"
end

defmodule Steward.Plane.V1.Session.Service do
  @moduledoc false

  use GRPC.Service, name: "steward.plane.v1.Session", protoc_gen_elixir_version: "0.17.1"

  rpc(
    :Connect,
    stream(Steward.Plane.V1.DataPlaneMessage),
    stream(Steward.Plane.V1.ControlPlaneMessage)
  )
end

defmodule Steward.Plane.V1.Session.Stub do
  @moduledoc false

  use GRPC.Stub, service: Steward.Plane.V1.Session.Service
end

defmodule Steward.Plane.V1.Enrolment.Service do
  @moduledoc false

  use GRPC.Service, name: "steward.plane.v1.Enrolment", protoc_gen_elixir_version: "0.17.1"

  rpc(:Enrol, Steward.Plane.V1.EnrolRequest, Steward.Plane.V1.EnrolResponse)
end

defmodule Steward.Plane.V1.Enrolment.Stub do
  @moduledoc false

  use GRPC.Stub, service: Steward.Plane.V1.Enrolment.Service
end

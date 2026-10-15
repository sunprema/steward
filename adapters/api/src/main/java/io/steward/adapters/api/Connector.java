package io.steward.adapters.api;

import java.util.List;
import java.util.Optional;

/** The only public type an adapter exports. One instance per registered target. */
public interface Connector extends AutoCloseable {

    /** Static facts about the target: tables, columns and types, primary keys,
     *  which tables can supply before-images cheaply, whether true snapshots exist.
     *  Must be cheap (cached by the adapter; refreshed on explicit request). */
    TargetDescription describe() throws ConnectorException;

    /** What this adapter can do, so the merge worker can plan apply. */
    Capabilities capabilities();

    /** Realise a base snapshot for a branch. Returns a stable reference that
     *  readRows/openSnapshotConnection accept until closeSnapshot or until the
     *  target loses it (SNAPSHOT_LOST). Idempotent on targetRef + branchId. */
    SnapshotHandle openSnapshot(TargetRef targetRef, BranchId branchId) throws ConnectorException;

    /** Release the snapshot. Idempotent; a missing snapshot is not an error. */
    void closeSnapshot(SnapshotHandle snapshot) throws ConnectorException;

    /** Keyed reads as of the snapshot. Missing keys are absent from the result,
     *  never an error. Keys per call bounded by capabilities().maxReadKeys(). */
    RowBatch readRows(SnapshotHandle snapshot, TableRef table, List<RowKey> keys)
            throws ConnectorException;

    /** Full scan of a table as of the snapshot. Named so nobody calls it by
     *  accident: it costs O(table) on the target and must only be used by the
     *  changeset engine for tables under capabilities().bulkScanRowLimit(). */
    RowStream scanTableExpensive(SnapshotHandle snapshot, TableRef table, Optional<Projection> columns)
            throws ConnectorException;

    /** A snapshot-scoped connection descriptor the proxy can use for pass-through
     *  reads in the target's own protocol. Empty when the target has no such
     *  mode (Salesforce). The credential inside is ephemeral and read-only. */
    Optional<SnapshotConnection> openSnapshotConnection(SnapshotHandle snapshot)
            throws ConnectorException;

    /** Current (not snapshot) rows for the staleness check. Includes the
     *  target's last-modified marker per row when the target exposes one. */
    RowBatch currentRows(TableRef table, List<RowKey> keys) throws ConnectorException;

    /** Apply a row delta. Idempotent per (mergeId, table, rowKey); resumable:
     *  rows already confirmed under mergeId are skipped. Reports each row's
     *  confirmation to the sink before returning. Partial progress is normal
     *  on non-transactional targets (doc 13 §6.5). */
    ApplyResult apply(MergeId mergeId, RowDelta delta, ProgressSink progress)
            throws ConnectorException;

    /** Close pools and release credentials. */
    @Override void close();
}

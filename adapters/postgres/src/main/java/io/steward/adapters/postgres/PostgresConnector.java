package io.steward.adapters.postgres;

import io.steward.adapters.api.ApplyResult;
import io.steward.adapters.api.BranchId;
import io.steward.adapters.api.Capabilities;
import io.steward.adapters.api.Connector;
import io.steward.adapters.api.ConnectorException;
import io.steward.adapters.api.MergeId;
import io.steward.adapters.api.ProgressSink;
import io.steward.adapters.api.Projection;
import io.steward.adapters.api.RowBatch;
import io.steward.adapters.api.RowDelta;
import io.steward.adapters.api.RowKey;
import io.steward.adapters.api.RowStream;
import io.steward.adapters.api.SnapshotConnection;
import io.steward.adapters.api.SnapshotHandle;
import io.steward.adapters.api.TableRef;
import io.steward.adapters.api.TargetDescription;
import io.steward.adapters.api.TargetRef;
import java.util.List;
import java.util.Optional;

/** M0 Postgres connector (doc 08 §5.1, §5.2). Skeleton: every method is unimplemented. */
public final class PostgresConnector implements Connector {

    private static UnsupportedOperationException notYet() {
        return new UnsupportedOperationException("PostgresConnector is not implemented yet (doc 08 §5)");
    }

    @Override
    public TargetDescription describe() throws ConnectorException {
        throw notYet();
    }

    @Override
    public Capabilities capabilities() {
        throw notYet();
    }

    @Override
    public SnapshotHandle openSnapshot(TargetRef targetRef, BranchId branchId) throws ConnectorException {
        throw notYet();
    }

    @Override
    public void closeSnapshot(SnapshotHandle snapshot) throws ConnectorException {
        throw notYet();
    }

    @Override
    public RowBatch readRows(SnapshotHandle snapshot, TableRef table, List<RowKey> keys)
            throws ConnectorException {
        throw notYet();
    }

    @Override
    public RowStream scanTableExpensive(SnapshotHandle snapshot, TableRef table, Optional<Projection> columns)
            throws ConnectorException {
        throw notYet();
    }

    @Override
    public Optional<SnapshotConnection> openSnapshotConnection(SnapshotHandle snapshot)
            throws ConnectorException {
        throw notYet();
    }

    @Override
    public RowBatch currentRows(TableRef table, List<RowKey> keys) throws ConnectorException {
        throw notYet();
    }

    @Override
    public ApplyResult apply(MergeId mergeId, RowDelta delta, ProgressSink progress) throws ConnectorException {
        throw notYet();
    }

    @Override
    public void close() {
        throw notYet();
    }
}

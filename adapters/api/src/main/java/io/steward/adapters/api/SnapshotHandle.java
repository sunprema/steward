package io.steward.adapters.api;

import java.time.Instant;

/**
 * A stable reference to a realised base snapshot (doc 08 §3). Returned by
 * {@link Connector#openSnapshot} and accepted by {@code readRows} and
 * {@code openSnapshotConnection} until {@code closeSnapshot} or until the target
 * loses it ({@code SNAPSHOT_LOST}).
 */
public record SnapshotHandle(String targetRef, String token, Fidelity fidelity, Instant openedAt) {

    /** How faithful the snapshot is (doc 08 §3; also the manifest's {@code base_snapshot_fidelity}, doc 12 §8.4). */
    public enum Fidelity {
        /** A true point-in-time snapshot (CoW branch, Iceberg snapshot, exported Postgres snapshot). */
        TRUE_SNAPSHOT,
        /** Reads are bounded by a last-modified timestamp rather than a real snapshot (Salesforce). */
        TIMESTAMP_BOUNDED
    }
}

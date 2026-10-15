package io.steward.adapters.api;

import java.time.Instant;

/**
 * Snapshot-scoped connection descriptor for pass-through reads (doc 08 §3, §5.1).
 * The credential is ephemeral and read-only; it never reaches the control plane.
 */
public record SnapshotConnection(String connectionString, Instant expiresAt) {}

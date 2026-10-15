package io.steward.adapters.api;

import java.time.Duration;
import java.util.Objects;
import java.util.Optional;

/**
 * Every failure crosses the connector boundary as
 * {@code ConnectorException(code, safeMessage, retryAfter?)} (doc 08 §3.1).
 * Checked exceptions are never thrown across the boundary (doc 18 §2); adapters
 * wrap them here with a stable {@link ErrorCode}. {@code safeMessage} must not
 * contain row values. The codes are the gRPC {@code status.details}.
 */
public final class ConnectorException extends RuntimeException {

    private static final long serialVersionUID = 1L;

    /** Stable error codes (doc 08 §3.1). The ordinal is not part of the contract; the name is. */
    public enum ErrorCode {
        /** The snapshot handle no longer resolves (CoW branch GC'd, Iceberg snapshot
         *  expired, exported snapshot's transaction ended). Not retryable; reported via
         *  heartbeat and the control plane abandons the branch with lifecycle reason
         *  {@code snapshot_lost} (doc 13 §2.1, §6.2). */
        SNAPSHOT_LOST,
        /** {@code currentRows} detected a row the base does not match; raised only by the
         *  merge worker's comparison, never by the adapter itself, but reserved here so
         *  the proto has it. Not retryable. */
        STALE_BASE,
        /** Target refused for quota; {@code retryAfter} populated. Retryable after {@code retryAfter}. */
        RATE_LIMITED,
        /** Apply returned with some rows unconfirmed; progress sink has the detail.
         *  Retryable: resume with the same merge ID. */
        PARTIAL_APPLY,
        /** Credential rejected. Retryable after rotation. */
        AUTH_FAILED,
        /** Target schema at apply time is incompatible with the base snapshot's (doc 08 §5.4). Not retryable. */
        SCHEMA_MISMATCH,
        /** Network or connection failure. Retryable with backoff. */
        TARGET_UNREACHABLE,
        /** No connection available within the pool timeout. Retryable. */
        POOL_EXHAUSTED,
        /** Caller exceeded {@code maxReadKeys} or {@code maxApplyBatchRows}. Not retryable; caller bug. */
        KEY_LIMIT_EXCEEDED,
        /** Operation not offered by this adapter ({@code openSnapshotConnection} on Salesforce). Not retryable. */
        UNSUPPORTED,
        /** Adapter bug; always paired with a log line carrying a correlation ID. Not retryable. */
        INTERNAL
    }

    private final ErrorCode code;
    private final transient Duration retryAfter;

    /** Creates an exception with no retry hint. */
    public ConnectorException(ErrorCode code, String safeMessage) {
        this(code, safeMessage, null, null);
    }

    /** Creates an exception wrapping a cause; the cause's message is never exposed. */
    public ConnectorException(ErrorCode code, String safeMessage, Throwable cause) {
        this(code, safeMessage, null, cause);
    }

    /** Creates an exception with a retry hint (used by {@link ErrorCode#RATE_LIMITED}). */
    public ConnectorException(ErrorCode code, String safeMessage, Duration retryAfter) {
        this(code, safeMessage, retryAfter, null);
    }

    private ConnectorException(ErrorCode code, String safeMessage, Duration retryAfter, Throwable cause) {
        super(Objects.requireNonNull(safeMessage, "safeMessage"), cause);
        this.code = Objects.requireNonNull(code, "code");
        this.retryAfter = retryAfter;
    }

    /** The stable error code. */
    public ErrorCode code() {
        return code;
    }

    /** The message safe to cross the plane boundary; never contains row values. */
    public String safeMessage() {
        return getMessage();
    }

    /** When the caller may retry, if the target said so. */
    public Optional<Duration> retryAfter() {
        return Optional.ofNullable(retryAfter);
    }
}

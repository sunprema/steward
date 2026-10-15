package io.steward.adapters.api;

import java.util.Optional;

/** What an adapter can do, so the merge worker can plan apply (doc 08 §3). */
public record Capabilities(
        /** Whole delta in one target transaction. */
        boolean transactionalApply,
        /** Rows per statement/request. */
        int maxApplyBatchRows,
        /** Keys per {@code readRows} call. */
        int maxReadKeys,
        /** {@code scanTableExpensive} refused above this. */
        long bulkScanRowLimit,
        /** Requests per window, when the target meters. */
        Optional<RateLimit> rateLimit,
        /** {@code openSnapshotConnection} returns non-empty. */
        boolean supportsPassThrough,
        /** {@code readRows} on snapshot is O(keys), not O(table). */
        boolean beforeImagesCheap) {}

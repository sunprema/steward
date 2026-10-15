package io.steward.adapters.api;

import io.steward.adapters.api.ConnectorException.ErrorCode;

/** Row-keyed progress. The merge worker persists it (doc 13 §6.5 step 9). */
public interface ProgressSink {
    void confirmed(TableRef table, RowKey key);
    void failed(TableRef table, RowKey key, ErrorCode code, String safeMessage);
}

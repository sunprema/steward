package io.steward.adapters.api;

import java.util.Iterator;

/** A streamed table scan; closing releases the target cursor. */
public interface RowStream extends Iterator<RowBatch>, AutoCloseable {
    @Override void close();
}

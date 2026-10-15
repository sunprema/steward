package io.steward.adapters.api;

import java.util.List;

/**
 * The row-delta layer of a changeset (doc 02 §1), streamed in table order,
 * inserts before updates before deletes within a table (doc 08 §3).
 * Minimal M0 shape; row images are opaque until the Arrow types land.
 */
public record RowDelta(String changesetId, List<TableDelta> tables) {

    /** One table's rows in the delta. */
    public record TableDelta(TableRef table, List<Row> inserts, List<Row> updates, List<Row> deletes) {}

    /** One row of the delta: key plus before/after images (null per doc 05 §4.1). */
    public record Row(RowKey key, byte[] before, byte[] after) {}
}

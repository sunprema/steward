package io.steward.adapters.api;

import java.util.List;

/**
 * Static facts about the target (doc 08 §3): per table, columns with nominal
 * types, the primary key, whether rows carry a last-modified marker, and
 * {@code beforeImagesCheap}.
 */
public record TargetDescription(List<Table> tables, boolean trueSnapshots) {

    /** One table's description. */
    public record Table(
            TableRef ref,
            List<Column> columns,
            List<String> primaryKey,
            boolean hasLastModifiedMarker,
            boolean beforeImagesCheap) {}

    /** One column with its nominal target type name. */
    public record Column(String name, String nominalType, boolean nullable) {}
}

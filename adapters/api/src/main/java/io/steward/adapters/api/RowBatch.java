package io.steward.adapters.api;

import java.util.List;

/** Rows returned by a keyed read. Missing keys are simply absent. Opaque row images until Arrow types land. */
public record RowBatch(TableRef table, List<RowDelta.Row> rows) {}

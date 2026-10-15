package io.steward.adapters.api;

import java.util.List;

/** Canonical primary-key value of one row, in primary-key column order (doc 05 §4.1 {@code key}). */
public record RowKey(List<Object> values) {}

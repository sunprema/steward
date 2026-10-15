package io.steward.adapters.api;

/** Merge identifier; the idempotency scope of {@link Connector#apply}. */
public record MergeId(String id) {}

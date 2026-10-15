package io.steward.adapters.api;

/** A table on the target, as {@code schema.name} (schema may be empty for targets without one). */
public record TableRef(String schema, String name) {}

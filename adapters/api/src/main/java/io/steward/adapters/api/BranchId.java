package io.steward.adapters.api;

/** Branch identifier (UUID string; doc 04 §3.1 uses it as the database name). */
public record BranchId(String id) {}

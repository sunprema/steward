package io.steward.adapters.api;

/** Outcome of {@link Connector#apply}: counts of rows confirmed and rows left unconfirmed under this merge. */
public record ApplyResult(long confirmedRows, long unconfirmedRows) {}

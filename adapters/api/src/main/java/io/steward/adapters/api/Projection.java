package io.steward.adapters.api;

import java.util.List;

/** Column subset for {@link Connector#scanTableExpensive}. */
public record Projection(List<String> columns) {}

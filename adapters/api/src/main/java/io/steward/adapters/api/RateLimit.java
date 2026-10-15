package io.steward.adapters.api;

import java.time.Duration;

/** Requests per window, when the target meters (doc 08 §3 {@code Capabilities.rateLimit}). */
public record RateLimit(int requests, Duration window) {}

package io.steward.adapters.api;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import io.steward.adapters.api.ConnectorException.ErrorCode;
import java.util.EnumSet;
import java.util.List;
import org.junit.jupiter.api.Test;

/** Pins the error-code enum to the table in doc 08 §3.1. */
class ConnectorExceptionCodesTest {

    private static final List<String> DOC_08_CODES = List.of(
            "SNAPSHOT_LOST",
            "STALE_BASE",
            "RATE_LIMITED",
            "PARTIAL_APPLY",
            "AUTH_FAILED",
            "SCHEMA_MISMATCH",
            "TARGET_UNREACHABLE",
            "POOL_EXHAUSTED",
            "KEY_LIMIT_EXCEEDED",
            "UNSUPPORTED",
            "INTERNAL");

    @Test
    void enumHasEveryCodeFromDoc08() {
        for (String name : DOC_08_CODES) {
            assertTrue(
                    EnumSet.allOf(ErrorCode.class).stream().anyMatch(c -> c.name().equals(name)),
                    "missing code " + name);
        }
        assertEquals(DOC_08_CODES.size(), ErrorCode.values().length, "codes not in doc 08 §3.1");
    }

    @Test
    void retryAfterIsOptional() {
        var e = new ConnectorException(ErrorCode.RATE_LIMITED, "quota exhausted");
        assertTrue(e.retryAfter().isEmpty());
        assertEquals("quota exhausted", e.safeMessage());
    }
}

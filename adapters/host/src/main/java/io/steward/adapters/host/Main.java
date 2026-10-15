package io.steward.adapters.host;

/**
 * Thin adapter host (doc 08 §6, §3.1): loads adapter jars (a jar that fails to
 * load marks its target kind {@code unavailable} and the host starts anyway),
 * exposes {@code steward.adapter.v1.Adapter} over gRPC on a Unix domain socket
 * inside the data-plane pod, and holds open snapshot handles and HikariCP pools
 * in memory only. No framework (doc 18 §2). The gRPC server is not wired yet.
 */
public final class Main {

    /** Host version string. */
    public static final String VERSION = "0.1.0";

    private Main() {}

    public static void main(String[] args) {
        System.out.println("steward-adapter-host " + VERSION);
    }
}

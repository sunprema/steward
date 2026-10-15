//! `steward-engine`: the changeset engine (doc 05).
//!
//! Runs as its own process in the data-plane pod next to the proxy and the
//! adapter host, speaking gRPC over a Unix domain socket (doc 05 §5.1). It
//! computes row deltas, summaries and impact, runs policy assertions in a
//! sandboxed DuckDB, performs the staleness check and compensation at merge,
//! and sends the per-branch heartbeat (doc 13 §6.8).
//!
//! The overlay format itself lives in the shared [`steward_overlay`] crate.

pub mod changeset;
pub mod sandbox;

/// Crate version as compiled.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

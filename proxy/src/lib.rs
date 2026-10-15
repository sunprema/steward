//! `steward-proxy`: the write proxy (doc 04).
//!
//! Terminates agent connections over the Postgres wire protocol, resolves the
//! branch from the local routing store, classifies every statement (§5.2),
//! serves reads with read-your-writes semantics and appends writes to the
//! branch overlay through the shared [`steward_overlay`] crate before
//! acknowledging them. It never calls the control plane synchronously.

pub mod classify;
pub mod routing;

/// Crate version as compiled.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

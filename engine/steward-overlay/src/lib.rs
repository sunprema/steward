//! `steward-overlay`: the shared overlay crate linked into both the write proxy
//! (doc 04) and the changeset engine (doc 05).
//!
//! It owns the overlay format (doc 05 §1): the per-branch write-ahead log
//! (doc 12 §8.2), the Parquet segment schema (doc 05 §4.1, doc 12 §8.3), the
//! manifest and freeze marker (doc 12 §8.4), the WAL-to-Parquet roll, and the
//! `view()` relation the proxy uses for read-your-writes reads (doc 05 §5.5).
//!
//! This is the M0 skeleton: types only, no logic.

pub mod segment;
pub mod wal;

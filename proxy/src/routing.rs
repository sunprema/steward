//! Connection and branch resolution (doc 04 §5.1) against the routing store
//! (SQLite, WAL mode; doc 04 §4, doc 12 §8.6), and the `SD`-class SQLSTATEs the
//! proxy raises (doc 04 §5–§6, doc 10 §2.1, doc 11 §4.1).
//!
//! M0 skeleton: types only, no logic.

/// Steward-specific SQLSTATE codes in the `SD` class returned by the proxy.
///
/// The five-character code is the wire value; the proxy name is the stable
/// identifier the SDKs map to exception classes (doc 11 §4.1). Messages never
/// echo SQL text, parameters, rationale or row values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SqlState {
    /// `SD001 branch_frozen`: the branch is `proposed` or later; writes and
    /// `COMMIT` are rejected (doc 04 §5.3, §5.4). Not retryable.
    BranchFrozen,
    /// `SD002 branch_not_routable`: the database name is not in the routing
    /// store (doc 04 §4). Retryable; the SDK retries connect for up to 60 s.
    BranchNotRoutable,
    /// `SD003 branch_merged`: terminal state `merged` (doc 04 §5.1). Not retryable.
    BranchMerged,
    /// `SD004 base_snapshot_gone`: the adapter lost the base snapshot
    /// (doc 04 §6, doc 13 §6.2 failure 3). Not retryable; create a new branch.
    BaseSnapshotGone,
    /// `SD005 unsupported_statement`: DDL, `COPY`, `LOCK`, `FOR UPDATE`,
    /// sequences, writes without a primary key, … (doc 04 §5.2). Not retryable.
    UnsupportedStatement,
    /// `SD006 unclassifiable`: the statement did not parse, or the classifier
    /// panicked on it (doc 04 §5.2, §6). Not retryable.
    Unclassifiable,
    /// `SD007 proxy_unavailable`: routing store, overlay store, adapter stream
    /// or engine unavailable (doc 04 §5.1, §6). Retryable.
    ProxyUnavailable,
    /// `SD008 transaction_too_large`: the transaction buffer exceeded the
    /// per-transaction ceiling (doc 04 §5.3, §7); aborted until `ROLLBACK`.
    TransactionTooLarge,
    /// `SD009 statement_too_large`: a merged read or write exceeded the
    /// per-statement caps (doc 04 §7). Not retryable; add a predicate.
    StatementTooLarge,
    /// `SD00A branch_rejected`: terminal state `rejected` (doc 04 §5.1).
    BranchRejected,
    /// `SD00B branch_abandoned`: terminal state `abandoned` (doc 04 §5.1).
    BranchAbandoned,
    /// `SD00C branch_closed`: terminal state `closed` (doc 04 §5.1).
    BranchClosed,
}

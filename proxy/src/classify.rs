//! Statement classification (doc 04 §5.2).
//!
//! Every statement is classified from its abstract syntax tree, never by regular
//! expression, into exactly one [`StatementClass`]. Fail closed: anything not
//! positively classified is rejected. Classification is protocol-independent and
//! written against an internal `Statement` type so the MySQL front end adds a
//! parser, not a second router (doc 04 §3.1).
//!
//! M0 skeleton: types only, no logic.

/// Statement classes (doc 04 §1, §5.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StatementClass {
    /// `SELECT` / `VALUES` / `EXPLAIN SELECT`: pass-through or merged read.
    Read,
    /// `INSERT` / `UPDATE` / `DELETE` / `MERGE`: evaluated and appended to the overlay.
    Write,
    /// `CREATE` / `ALTER` / `DROP` / `TRUNCATE` / `GRANT` …: rejected with `SD005` in M0.
    Ddl,
    /// `BEGIN` / `COMMIT` / `ROLLBACK` / `SAVEPOINT`: overlay batch semantics (§5.3).
    TxnControl,
    /// `SET` / `SHOW` / `RESET` / `DISCARD` / `DEALLOCATE`.
    Session,
    /// `COPY`, `LISTEN`, `VACUUM`, `CALL`, `DO`, `LOCK`, side-effecting functions,
    /// anything else: rejected with `SD005`.
    Unsupported,
    /// Parse error: rejected with `SD006`.
    Unclassifiable,
}

//! Changeset computation (doc 05 §5.2): net-op collapse of the frozen overlay
//! into a row delta persisted under `<data_dir>/changesets/<changeset_id>/`,
//! the summary layer, registered impact queries (§5.3), and the `conflicts`
//! section for `stale_base` and revert changesets (doc 13 §6.5, §6.6).
//!
//! M0 skeleton: intentionally empty.

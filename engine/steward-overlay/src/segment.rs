//! Overlay Parquet segment schema, manifest and freeze marker.
//! Authoritative definitions: doc 05 §4.1, doc 12 §8.3 and §8.4.
//!
//! Segments live at
//! `steward/targets/<target_id>/overlays/<overlay_id>/tables/<table>/segments/seg-<first_seq>-<last_seq>.parquet`
//! and are immutable once written (doc 05 §4). The compensation body
//! (doc 09 §5.1) uses this same schema with the same column names.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Row operation (`op` column, UTF8 dictionary; doc 05 §4.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Op {
    /// A row inserted on the branch; `before` is null.
    Insert,
    /// A row updated on the branch; `touched` lists the assigned columns.
    Update,
    /// A row deleted on the branch; `after` is null.
    Delete,
}

/// One row of an overlay segment, in the column order of doc 05 §4.1 / doc 12 §8.3.
///
/// `key`, `before` and `after` are structs whose fields are the target table's
/// columns in the adapter's canonical Arrow types; this skeleton carries them
/// as opaque Arrow-encoded bytes until the Arrow dependency is introduced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Segment {
    /// INT64 required. Overlay-wide, strictly increasing sequence number
    /// assigned by the proxy at append; the write's idempotency key.
    pub seq: i64,
    /// UTF8 dictionary required: `insert` / `update` / `delete`.
    pub op: Op,
    /// STRUCT of the table's primary-key columns, required. Row identity.
    pub key: Vec<u8>,
    /// `FIXED_LEN_BYTE_ARRAY(16)` required. xxh3-128 of the canonical key encoding;
    /// join and bloom-filter column.
    pub key_hash: [u8; 16],
    /// STRUCT nullable. Full row image before the op as seen through the branch.
    /// Null for `insert`; null for `update`/`delete` only when the adapter cannot
    /// provide it (doc 05 §12).
    pub before: Option<Vec<u8>>,
    /// STRUCT nullable. Full row image after the op. Null for `delete`.
    pub after: Option<Vec<u8>>,
    /// LIST<UTF8> required. Columns the statement assigned; every column for
    /// `insert` and `delete`.
    pub touched: Vec<String>,
    /// TIMESTAMP(MICROS, UTC) required. Proxy wall clock at append.
    pub ts: i64,
    /// UTF8 required. Evidence correlation id (`<connection_id>:<evidence seq>`);
    /// never the statement text.
    pub stmt_id: String,
}

/// One live segment entry in the manifest (doc 12 §8.4 `tables.<table>.segments[]`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestSegment {
    /// Object-store path of the Parquet file.
    pub path: String,
    /// First `seq` contained in the segment.
    pub first_seq: i64,
    /// Last `seq` contained in the segment.
    pub last_seq: i64,
    /// Row count.
    pub rows: u64,
    /// Compressed size in bytes.
    pub bytes: u64,
}

/// Per-table entry in the manifest (doc 12 §8.4 `tables.<table>`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestTable {
    /// `sha256:…` fingerprint of the table's schema at the base snapshot.
    pub schema_fingerprint: String,
    /// Every segment with `last_seq <= compacted_through_seq` has been folded
    /// into a `compact-<last_seq>.parquet` (doc 05 §4.2).
    pub compacted_through_seq: i64,
    /// Live segments for this table.
    pub segments: Vec<ManifestSegment>,
}

/// `manifest.json` (doc 12 §8.4). Updated by conditional PUT, so a stale writer
/// loses and re-reads (doc 05 §4.1); readers reject a newer major version.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    /// Manifest format version, `"1.0"`.
    pub version: String,
    /// Overlay this manifest describes.
    pub overlay_id: String,
    /// Branch that owns the overlay.
    pub branch_id: String,
    /// Target the branch was opened on.
    pub target_id: String,
    /// Opaque adapter snapshot reference (doc 08 `SnapshotHandle`).
    pub base_snapshot_ref: String,
    /// `TRUE_SNAPSHOT` or `TIMESTAMP_BOUNDED` (doc 08 §3 `Fidelity`).
    pub base_snapshot_fidelity: String,
    /// RFC 3339 creation time.
    pub created_at: String,
    /// Set for revert overlays: the merge being reverted (doc 09 §5.3).
    pub revert_of: Option<String>,
    /// Set for revert overlays: checksum of the compensation record applied.
    pub compensation_checksum: Option<String>,
    /// Per-table segment lists keyed by table name.
    pub tables: BTreeMap<String, ManifestTable>,
}

/// `freeze.json` (doc 12 §8.4), written once by the proxy (doc 05 §4). Upper
/// bound on the sequence numbers a changeset includes (doc 13 §6.2 failure 6).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FreezeMarker {
    /// RFC 3339 time the freeze was applied.
    pub frozen_at: String,
    /// Last `seq` included in the changeset.
    pub last_seq: i64,
    /// Identity of the proxy instance that wrote the marker.
    pub proxy_instance: String,
    /// Sequence positions of any later UNFREEZE records (doc 04 §5.4).
    pub unfreeze_markers: Vec<i64>,
}

//! Overlay write-ahead log record format. Authoritative layout: doc 12 §8.2.
//!
//! Little-endian, one file per branch at `<data_dir>/wal/<overlay_id>.wal`,
//! appended and `fsync`'d by the proxy (the per-write checkpoint, doc 13 §6.2),
//! truncated only after the segment PUT and manifest update succeed.

/// Magic bytes at the start of every WAL file (doc 12 §8.2 file header).
pub const WAL_MAGIC: [u8; 4] = *b"SWOL";

/// WAL file format version carried in the file header (doc 12 §8.2).
pub const WAL_VERSION: u16 = 1;

/// Record kind discriminator (doc 12 §8.2 `u8 kind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum WalRecordKind {
    /// `0x01 BATCH`: payload is one Arrow IPC record batch in the segment schema
    /// (doc 12 §8.3); all rows share `seq` (one `COMMIT` = one batch = one seq,
    /// doc 04 §5.3).
    Batch = 0x01,
    /// `0x02 FREEZE`: payload `{}`; `seq` is the last seq included in the changeset.
    Freeze = 0x02,
    /// `0x03 UNFREEZE`: payload `{}`; ops between FREEZE and UNFREEZE are excluded
    /// (doc 04 §5.4).
    Unfreeze = 0x03,
    /// `0x04 ROLLED`: payload `u64 through_seq`; records `<= through_seq` are
    /// durable in object storage.
    Rolled = 0x04,
}

/// The WAL file header (doc 12 §8.2):
/// `magic "SWOL" | u16 version = 1 | u16 reserved | u128 overlay_id`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WalFileHeader {
    /// Always [`WAL_MAGIC`].
    pub magic: [u8; 4],
    /// Always [`WAL_VERSION`] for files this crate writes.
    pub version: u16,
    /// Reserved; written as zero.
    pub reserved: u16,
    /// The overlay this file belongs to, as the raw 128-bit UUID.
    pub overlay_id: u128,
}

/// One WAL record (doc 12 §8.2):
/// `u32 length | u32 crc32c | u8 kind | u64 seq | i64 ts_us | payload`.
///
/// A failed `crc32c` ends the readable prefix; the crate truncates there on
/// open, and nothing beyond it was ever acknowledged (doc 13 §6.2 f2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WalRecord {
    /// Length of everything after this field.
    pub length: u32,
    /// CRC-32C of `kind..payload`.
    pub crc32c: u32,
    /// Record kind.
    pub kind: WalRecordKind,
    /// Overlay-wide, strictly increasing sequence number assigned by the proxy
    /// at append; the write's idempotency key (doc 05 §4.1).
    pub seq: u64,
    /// Proxy wall clock at append, microseconds since the Unix epoch, UTC.
    pub ts_us: i64,
    /// Kind-specific payload; see [`WalRecordKind`].
    pub payload: Vec<u8>,
}

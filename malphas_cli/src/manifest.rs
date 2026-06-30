//! Typed manifest schema for the Malphas v2.9.0 workspace compiler.
//!
//! A workspace is a directory that contains:
//!   * `manifest.json`   — this file.
//!   * raw payload files — one per entity, referenced by `payload_file`.
//!
//! Schema contract accepted by the CLI:
//!
//!   {
//!     "pack_id": string,
//!     "entities": [
//!       {
//!         "entity_id": u32,
//!         "tag_mask": u64,
//!         "payload_file": string
//!       }
//!     ]
//!   }
//!
//! `#[serde(deny_unknown_fields)]` means any extra fields are rejected.  Callers
//! must strip additional metadata before passing a manifest to the compiler.

use serde::Deserialize;
use std::path::PathBuf;

/// Root manifest object.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub pack_id: String,
    pub entities: Vec<ManifestEntity>,
}

/// One entity declared in the manifest.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManifestEntity {
    pub entity_id: u32,
    #[serde(default)]
    pub tag_mask: u64,
    /// Relative path from the manifest directory to the raw payload file.
    pub payload_file: PathBuf,
}

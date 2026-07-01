//! Typed manifest schema for the Malphas v3.0.0 workspace compiler.
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
//!         "payload_type": string,  // optional, default "unknown"
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
    /// Logical payload type used by systems to interpret the payload bytes.
    #[serde(default = "default_payload_type")]
    pub payload_type: String,
    /// Relative path from the manifest directory to the raw payload file.
    pub payload_file: PathBuf,
}

fn default_payload_type() -> String {
    "unknown".to_string()
}

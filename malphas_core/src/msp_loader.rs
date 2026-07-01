// Zero-copy MSP (Malphas Source Pack) loader.
//
// The .msp file is mapped directly into virtual memory via mmap in read-only
// mode.  A flat "Silver Platter" lookup table of *const u8 pointers is built
// once at load time: lookup_table[entity_id] points to the absolute memory
// address of that entity's payload.  The last 64 KB of the payload section are
// reserved for hardcoded Error Payloads; invalid entity IDs resolve to that
// address so the hot path never crashes.
//
// Systems must treat payloads as immutable.  If a system needs mutable working
// memory it must allocate its own SoA state from the read-only static payloads.

use std::ffi::{c_char, CStr};
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::path::Path;
use std::sync::Arc;

use arc_swap::ArcSwapOption;
use memmap2::Mmap;
use sha2::{Digest, Sha256};

use crate::integrity_policy::global_trust_anchor;
use crate::memory_budget::{release, try_reserve, ERR_MEMORY_BUDGET_EXCEEDED};
use crate::payload_schema::{PayloadSchemaRegistry, PAYLOAD_TYPE_UNKNOWN};
use crate::pipeline::telemetry_now_micros;

pub const MSP_MAGIC: [u8; 4] = *b"MLPS";
pub const MSP_VERSION: u32 = 4;

/// Maximum size of an MSP file that the loader will map.  Files larger than
/// this are rejected before any memory is mapped.
pub const MAX_MSP_SIZE: u64 = 256 * 1024 * 1024;

const ERR_MSP_SIGNATURE_MISSING: i32 = -120;
const ERR_MSP_SIGNATURE_INVALID: i32 = -121;
const ERR_MSP_TOO_LARGE: i32 = -122;
const ERR_MSP_DUPLICATE_ENTITY_ID: i32 = -113;
const ERR_MSP_INVALID_LAYOUT: i32 = -114;

/// Space reserved at the end of the payload section for hardcoded Error
/// Payloads.  Every valid MSP must contain at least this many bytes of
/// payload data.
pub const ERROR_PAYLOAD_RESERVE: usize = 64 * 1024;

struct BudgetGuard(usize);

impl Drop for BudgetGuard {
    fn drop(&mut self) {
        release(self.0);
    }
}

/// 64-byte aligned MSP header.
///
/// Layout: 4 + 4 + 4 + 4 + 4 + 4 + 32 = 56 bytes of fields, plus 8 bytes of
/// manual padding to lock the struct size to exactly one cache line.
#[repr(C, align(64))]
#[derive(Clone, Copy, Debug)]
pub struct MspHeader {
    pub magic: [u8; 4],
    pub version: u32,
    pub entity_table_offset: u32,
    pub entity_count: u32,
    pub payload_section_offset: u32,
    pub payload_section_size: u32,
    pub checksum: [u8; 32],
    pub _padding: [u8; 8],
}

/// 64-byte aligned entity descriptor.
///
/// The field order is fixed by the v3.0.0 MSP format.  The 4-byte gap between
/// `entity_id` and `tag_mask` is used for `payload_type_id`, leaving 40 bytes
/// of explicit padding so the total struct size remains exactly 64 bytes.
#[repr(C, align(64))]
#[derive(Clone, Copy, Debug)]
pub struct MspEntityDescriptor {
    pub entity_id: u32,
    pub payload_type_id: u32,
    pub tag_mask: u64,
    pub payload_offset: u32,
    pub payload_size: u32,
    pub _padding: [u8; 40],
}

/// Deterministic SHA-256 digest over a byte slice.
///
/// The CLI computes the same digest over the entity table and payload section
/// so the file can be validated without heap allocations at load time.
pub fn compute_msp_sha256(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

/// In-memory view of a mapped MSP.
#[allow(dead_code)]
pub struct MspMap {
    mmap: Mmap,
    lookup_table: Vec<*const u8>,
    entity_count: u32,
    payload_section_offset: u32,
    payload_section_size: u32,
    error_payload_ptr: *const u8,
    mapped_size: usize,
    build_time_micros: u64,
}

// SAFETY: The mmap-backed pointer table is read-only after construction and
// the underlying Mmap is Send + Sync, so it is safe to share across threads.
unsafe impl Send for MspMap {}
unsafe impl Sync for MspMap {}

impl MspMap {
    /// Map an MSP file from disk in read-only mode.
    pub fn load(path: &Path) -> Result<Self, i32> {
        let file = OpenOptions::new().read(true).open(path).map_err(|_| -100)?;
        let metadata = file.metadata().map_err(|_| -100)?;
        if metadata.len() > MAX_MSP_SIZE {
            return Err(ERR_MSP_TOO_LARGE);
        }
        // SAFETY: We map the opened file read-only.  The mapping is never
        // written through by Rust code; systems must treat the payload pointer
        // range as immutable.
        let mmap = unsafe { Mmap::map(&file).map_err(|_| -101)? };
        Self::from_mmap(mmap)
    }

    fn from_mmap(mmap: Mmap) -> Result<Self, i32> {
        let mapped_size = mmap.len();
        try_reserve(mapped_size).map_err(|_| ERR_MEMORY_BUDGET_EXCEEDED)?;
        let _budget_guard = BudgetGuard(mapped_size);

        let base = mmap.as_ptr();
        let len = mmap.len();

        if len < std::mem::size_of::<MspHeader>() {
            return Err(-102);
        }

        // SAFETY: `base` points to the start of the mmap and `len` was checked to
        // be at least `size_of::<MspHeader>()`, so the header is fully contained.
        let header = unsafe { std::ptr::read_unaligned(base as *const MspHeader) };

        if header.magic != MSP_MAGIC {
            return Err(-103);
        }
        if header.version != MSP_VERSION {
            return Err(-104);
        }

        let entity_table_offset = header.entity_table_offset as usize;
        let entity_count = header.entity_count as usize;
        let payload_section_offset = header.payload_section_offset as usize;
        let payload_section_size = header.payload_section_size as usize;
        let header_size = std::mem::size_of::<MspHeader>();

        // All major sections must start on a 64-byte boundary.
        if !entity_table_offset.is_multiple_of(64) || !payload_section_offset.is_multiple_of(64) {
            return Err(-105);
        }

        // Strict section ordering: the entity table must start after the header
        // and the payload section must start after the entity table ends.  This
        // prevents overlapping sections and keeps the checksum region contiguous.
        if entity_table_offset < header_size {
            return Err(ERR_MSP_INVALID_LAYOUT);
        }

        let descriptor_size = std::mem::size_of::<MspEntityDescriptor>();
        let entity_table_end = entity_table_offset
            .checked_add(entity_count.checked_mul(descriptor_size).ok_or(-106)?)
            .ok_or(-106)?;
        if payload_section_offset < entity_table_end {
            return Err(ERR_MSP_INVALID_LAYOUT);
        }

        // Reject header-claimed sizes that would exceed the absolute maximum
        // before checking them against the (possibly smaller) file length.
        let max_size = MAX_MSP_SIZE as usize;
        if payload_section_size > max_size || entity_table_end > max_size {
            return Err(ERR_MSP_TOO_LARGE);
        }

        if entity_table_end > len {
            return Err(-106);
        }

        let payload_section_end = payload_section_offset
            .checked_add(payload_section_size)
            .ok_or(-107)?;
        if payload_section_end > len {
            return Err(-107);
        }

        if payload_section_size < ERROR_PAYLOAD_RESERVE {
            return Err(-108);
        }

        // Checksum covers entity table + payload section (everything after the
        // header that is not padding).
        let checksum = compute_msp_sha256(&mmap[entity_table_offset..payload_section_end]);
        if checksum != header.checksum {
            return Err(-109);
        }

        // SAFETY: `payload_section_offset` and `payload_section_size` were
        // validated against the mapping length, so the resulting pointer lies
        // inside the read-only mmap.
        let payload_base = unsafe { base.add(payload_section_offset) };
        // SAFETY: `ERROR_PAYLOAD_RESERVE` is guaranteed <= `payload_section_size`,
        // so the offset stays inside the payload section within the mmap.
        let error_payload_ptr =
            unsafe { payload_base.add(payload_section_size - ERROR_PAYLOAD_RESERVE) };

        // Build the Silver Platter: a flat array indexed by entity ID.
        let build_start = telemetry_now_micros();
        let mut lookup_table = Vec::with_capacity(entity_count);
        lookup_table.resize(entity_count, error_payload_ptr);

        if entity_count > 0 {
            // SAFETY: `entity_table_offset` and `entity_count` were validated to
            // lie inside the mapped region and the section is 64-byte aligned,
            // matching the descriptor layout.
            let descriptors = unsafe {
                std::slice::from_raw_parts(
                    base.add(entity_table_offset) as *const MspEntityDescriptor,
                    entity_count,
                )
            };
            let registry = PayloadSchemaRegistry::default();
            let mut seen = vec![false; entity_count];
            for descriptor in descriptors {
                let id = descriptor.entity_id as usize;
                if id >= entity_count {
                    // Descriptor entity_id out of declared range: leave the
                    // error payload pointer in that slot.
                    continue;
                }
                if seen[id] {
                    return Err(ERR_MSP_DUPLICATE_ENTITY_ID);
                }
                seen[id] = true;

                // Validate payload type.  Known types must match the schema size;
                // unknown types are accepted for forward compatibility.
                let payload_type_id = descriptor.payload_type_id;
                let size = descriptor.payload_size as usize;
                if payload_type_id != PAYLOAD_TYPE_UNKNOWN {
                    if let Some(schema) = registry.get(payload_type_id) {
                        if size != schema.size {
                            // Size mismatch for a known payload type: point to
                            // the error payload so the system cannot misread it.
                            lookup_table[id] = error_payload_ptr;
                            continue;
                        }
                    }
                }

                let offset = descriptor.payload_offset as usize;
                if offset
                    .checked_add(size)
                    .is_none_or(|end| end > payload_section_size)
                {
                    lookup_table[id] = error_payload_ptr;
                } else {
                    // SAFETY: `offset` and `size` were checked to lie inside the
                    // payload section, so the resulting pointer is within the
                    // read-only mapping.
                    lookup_table[id] = unsafe { payload_base.add(offset) };
                }
            }
        }

        let build_time_micros = telemetry_now_micros().saturating_sub(build_start);
        std::mem::forget(_budget_guard);
        Ok(Self {
            mmap,
            lookup_table,
            entity_count: header.entity_count,
            payload_section_offset: header.payload_section_offset,
            payload_section_size: header.payload_section_size,
            error_payload_ptr,
            mapped_size,
            build_time_micros,
        })
    }
}

impl Drop for MspMap {
    fn drop(&mut self) {
        release(self.mapped_size);
    }
}

impl MspMap {
    /// Base pointer of the Silver Platter.  Systems read this once per tick:
    /// `let payload = *lookup_table.add(entity_id as usize);`
    #[inline]
    pub fn lookup_table_ptr(&self) -> *const *const u8 {
        self.lookup_table.as_ptr()
    }

    #[inline]
    pub fn entity_count(&self) -> u32 {
        self.entity_count
    }

    #[inline]
    pub fn error_payload_ptr(&self) -> *const u8 {
        self.error_payload_ptr
    }

    /// Bytes charged against the memory budget for this mapped MSP.
    #[inline]
    pub fn mapped_size_bytes(&self) -> u64 {
        self.mapped_size as u64
    }

    /// Time spent building the Silver Platter lookup table, in microseconds.
    #[inline]
    pub fn build_time_micros(&self) -> u64 {
        self.build_time_micros
    }

    /// Safe resolver used by the core before passing IDs to systems.  Invalid
    /// IDs always return the Error Payload pointer; the caller never crashes.
    #[inline]
    pub fn resolve_payload(&self, entity_id: u32) -> *const u8 {
        if entity_id < self.entity_count {
            // SAFETY: `entity_id` is in bounds and `lookup_table` has length
            // `entity_count`, so the offset is valid.
            unsafe { *self.lookup_table.as_ptr().add(entity_id as usize) }
        } else {
            self.error_payload_ptr
        }
    }
}

pub(crate) static MSP_MAP: ArcSwapOption<MspMap> = ArcSwapOption::const_empty();

/// Execute a read-only operation against the currently mapped MSP, if any.
pub fn with_msp_map<F, R>(f: F) -> Option<R>
where
    F: FnOnce(&MspMap) -> R,
{
    MSP_MAP.load_full().as_ref().map(|arc| f(arc))
}

/// Locate a sidecar Ed25519 signature file for an MSP.
///
/// Tries `<path>.msp.sig` first, then falls back to `<path>.sig`.
fn msp_signature_path(path: &Path) -> Option<std::path::PathBuf> {
    let sidecar = path.with_extension("msp.sig");
    if sidecar.exists() {
        return Some(sidecar);
    }
    let fallback = path.with_extension("sig");
    if fallback.exists() {
        return Some(fallback);
    }
    None
}

/// Load or reload an MSP from disk.  Replaces the previous map atomically.
///
/// The file must carry a valid Ed25519 sidecar signature unless the
/// `MALPHAS_INSECURE_SKIP_VERIFY` environment variable is set (debug only).
pub fn load_msp(path: &Path) -> Result<(), i32> {
    #[cfg(debug_assertions)]
    let skip_verify = std::env::var_os("MALPHAS_INSECURE_SKIP_VERIFY").is_some();
    #[cfg(not(debug_assertions))]
    let skip_verify = false;

    let signed_hash = if !skip_verify {
        let sig_path = msp_signature_path(path).ok_or(ERR_MSP_SIGNATURE_MISSING)?;
        let signature_hex =
            std::fs::read_to_string(&sig_path).map_err(|_| ERR_MSP_SIGNATURE_INVALID)?;
        let policy = global_trust_anchor().ok_or(ERR_MSP_SIGNATURE_INVALID)?;

        let mut file = File::open(path).map_err(|_| ERR_MSP_SIGNATURE_INVALID)?;
        let mut hasher = Sha256::new();
        let mut buffer = [0u8; 8192];
        loop {
            match file.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => hasher.update(&buffer[..n]),
                Err(_) => return Err(ERR_MSP_SIGNATURE_INVALID),
            }
        }
        let message_hash: [u8; 32] = hasher.finalize().into();

        policy
            .verify_ed25519_signature_prehash(&message_hash, &signature_hex)
            .map_err(|_| ERR_MSP_SIGNATURE_INVALID)?;
        Some(message_hash)
    } else {
        None
    };

    let new_map = MspMap::load(path)?;

    if let Some(expected) = signed_hash {
        let mapped_hash: [u8; 32] = Sha256::digest(&new_map.mmap).into();
        // SECURITY: Re-verify the mapped bytes against the hash that was signed.
        // This closes the TOCTOU window between signature verification and mmap
        // so the runtime never executes an image that differs from the signed
        // digest.  It does not remove all races (the file can still be swapped
        // between the size check and the first read), but it guarantees that
        // the mapped image is the one the signature covers.
        if mapped_hash != expected {
            return Err(ERR_MSP_SIGNATURE_INVALID);
        }
    }

    MSP_MAP.store(Some(Arc::new(new_map)));
    Ok(())
}

/// Unload the currently mapped MSP and release the mmap.
pub fn unload_msp() {
    MSP_MAP.store(None);
}

fn c_str_to_path<'a>(ptr: *const c_char) -> Option<&'a Path> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: The caller is required by the C-ABI contract to pass a valid,
    // NUL-terminated string.  We only convert it, never mutate it.
    unsafe { CStr::from_ptr(ptr).to_str().ok().map(Path::new) }
}

#[no_mangle]
pub extern "C" fn load_msp_file(filepath: *const c_char) -> i32 {
    match c_str_to_path(filepath) {
        Some(path) => match load_msp(path) {
            Ok(()) => 0,
            Err(code) => code,
        },
        None => -1,
    }
}

#[no_mangle]
pub extern "C" fn refresh_msp_file(filepath: *const c_char) -> i32 {
    load_msp_file(filepath)
}

pub(crate) fn get_msp_lookup_table_internal() -> *const *const u8 {
    with_msp_map(|m| m.lookup_table_ptr()).unwrap_or(std::ptr::null())
}

pub(crate) fn get_msp_entity_count_internal() -> u32 {
    with_msp_map(|m| m.entity_count()).unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp_msp_path(name: &str) -> std::path::PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!("malphas_test_{}_{}", name, std::process::id()));
        path
    }

    fn write_msp_file(
        path: &std::path::PathBuf,
        descriptors: &[MspEntityDescriptor],
        payload_section: &[u8],
    ) {
        let header_size = std::mem::size_of::<MspHeader>();

        let entity_table_offset = header_size;
        let payload_section_offset =
            (entity_table_offset + std::mem::size_of_val(descriptors)).div_ceil(64) * 64;

        let mut payload_section = payload_section.to_vec();
        // Reserve the error-payload region after any real payload data.
        payload_section.resize(payload_section.len() + ERROR_PAYLOAD_RESERVE, 0);
        let rem = payload_section.len() % 64;
        if rem != 0 {
            payload_section.resize(payload_section.len() + (64 - rem), 0);
        }

        let mut entity_table = Vec::new();
        for descriptor in descriptors {
            entity_table.extend_from_slice(&descriptor_as_bytes(descriptor));
        }

        let mut data = vec![0; payload_section_offset];
        data[entity_table_offset..entity_table_offset + entity_table.len()]
            .copy_from_slice(&entity_table);
        data.extend_from_slice(&payload_section);

        let checksum = compute_msp_sha256(&data[entity_table_offset..]);

        let header = MspHeader {
            magic: MSP_MAGIC,
            version: MSP_VERSION,
            entity_table_offset: entity_table_offset as u32,
            entity_count: descriptors.len() as u32,
            payload_section_offset: payload_section_offset as u32,
            payload_section_size: payload_section.len() as u32,
            checksum,
            _padding: [0; 8],
        };

        let mut file = std::fs::File::create(path).unwrap();
        file.write_all(&header_as_bytes(&header)).unwrap();
        file.write_all(&data[header_size..]).unwrap();
        file.flush().unwrap();
    }

    fn header_as_bytes(header: &MspHeader) -> [u8; 64] {
        let mut buf = [0u8; 64];
        buf[0..4].copy_from_slice(&header.magic);
        buf[4..8].copy_from_slice(&header.version.to_le_bytes());
        buf[8..12].copy_from_slice(&header.entity_table_offset.to_le_bytes());
        buf[12..16].copy_from_slice(&header.entity_count.to_le_bytes());
        buf[16..20].copy_from_slice(&header.payload_section_offset.to_le_bytes());
        buf[20..24].copy_from_slice(&header.payload_section_size.to_le_bytes());
        buf[24..56].copy_from_slice(&header.checksum);
        buf[56..64].copy_from_slice(&header._padding);
        buf
    }

    fn descriptor_as_bytes(descriptor: &MspEntityDescriptor) -> [u8; 64] {
        let mut buf = [0u8; 64];
        buf[0..4].copy_from_slice(&descriptor.entity_id.to_le_bytes());
        buf[8..16].copy_from_slice(&descriptor.tag_mask.to_le_bytes());
        buf[16..20].copy_from_slice(&descriptor.payload_offset.to_le_bytes());
        buf[20..24].copy_from_slice(&descriptor.payload_size.to_le_bytes());
        buf[24..64].copy_from_slice(&descriptor._padding);
        buf
    }

    #[test]
    fn msp_header_and_descriptor_are_64_bytes() {
        assert_eq!(std::mem::size_of::<MspHeader>(), 64);
        assert_eq!(std::mem::align_of::<MspHeader>(), 64);
        assert_eq!(std::mem::size_of::<MspEntityDescriptor>(), 64);
        assert_eq!(std::mem::align_of::<MspEntityDescriptor>(), 64);
    }

    #[test]
    fn load_valid_msp_builds_lookup_table() {
        let path = temp_msp_path("valid");
        let descriptors = vec![
            MspEntityDescriptor {
                entity_id: 0,
                payload_type_id: 0,
                tag_mask: 1,
                payload_offset: 0,
                payload_size: 64,
                _padding: [0; 40],
            },
            MspEntityDescriptor {
                entity_id: 1,
                payload_type_id: 0,
                tag_mask: 2,
                payload_offset: 64,
                payload_size: 64,
                _padding: [0; 40],
            },
        ];
        let mut payload_section = vec![0u8; 128];
        payload_section[0..4].copy_from_slice(b"ENT0");
        payload_section[64..68].copy_from_slice(b"ENT1");

        write_msp_file(&path, &descriptors, &payload_section);

        let map = MspMap::load(&path).expect("valid MSP must load");
        assert_eq!(map.entity_count(), 2);

        let table = map.lookup_table_ptr();
        assert!(!table.is_null());

        // SAFETY: The table has length `entity_count` (2) and was built by the
        // loader, so slots 0 and 1 are valid.
        let payload0 = unsafe { *table.add(0) };
        // SAFETY: Same as above.
        let payload1 = unsafe { *table.add(1) };
        assert!(!payload0.is_null());
        assert!(!payload1.is_null());

        // SAFETY: `payload0` points to at least 4 valid bytes inside the mapped
        // payload section.
        assert_eq!(unsafe { std::slice::from_raw_parts(payload0, 4) }, b"ENT0");
        // SAFETY: Same as above.
        assert_eq!(unsafe { std::slice::from_raw_parts(payload1, 4) }, b"ENT1");

        // Invalid IDs must resolve to the Error Payload area.
        let error_payload = map.resolve_payload(99);
        assert_eq!(error_payload, map.error_payload_ptr());

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn invalid_entity_descriptor_points_to_error_payload() {
        let path = temp_msp_path("invalid_desc");
        let descriptors = vec![
            MspEntityDescriptor {
                entity_id: 0,
                payload_type_id: 0,
                tag_mask: 1,
                payload_offset: 0,
                payload_size: 64,
                _padding: [0; 40],
            },
            MspEntityDescriptor {
                entity_id: 99, // Out of range.
                payload_type_id: 0,
                tag_mask: 2,
                payload_offset: 64,
                payload_size: 64,
                _padding: [0; 40],
            },
        ];
        let payload_section = vec![0u8; 128];
        write_msp_file(&path, &descriptors, &payload_section);

        let map = MspMap::load(&path).expect("MSP with invalid descriptor must still load");
        let table = map.lookup_table_ptr();

        // SAFETY: The table has length `entity_count` (2) and was built by the
        // loader, so slots 0 and 1 are valid.
        assert_ne!(unsafe { *table.add(0) }, map.error_payload_ptr());
        // SAFETY: Same as above.
        assert_eq!(unsafe { *table.add(1) }, map.error_payload_ptr());

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn out_of_bounds_payload_points_to_error_payload() {
        let path = temp_msp_path("oob_payload");
        let descriptors = vec![MspEntityDescriptor {
            entity_id: 0,
            payload_type_id: 0,
            tag_mask: 1,
            payload_offset: 0,
            payload_size: 1_000_000, // Larger than section.
            _padding: [0; 40],
        }];
        let payload_section = vec![0u8; 128];
        write_msp_file(&path, &descriptors, &payload_section);

        let map = MspMap::load(&path).expect("MSP with OOB payload must still load");
        assert_eq!(map.resolve_payload(0), map.error_payload_ptr());

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn bad_checksum_rejects_msp() {
        let path = temp_msp_path("bad_checksum");
        let descriptors = vec![];
        let payload_section = vec![0u8; ERROR_PAYLOAD_RESERVE];
        write_msp_file(&path, &descriptors, &payload_section);

        // Corrupt a payload byte after writing.
        let mut bytes = std::fs::read(&path).unwrap();
        let last = bytes.len() - 1;
        bytes[last] = bytes[last].wrapping_add(1);
        std::fs::write(&path, &bytes).unwrap();

        let result = MspMap::load(&path);
        assert!(matches!(result, Err(-109)));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn oversized_msp_is_rejected() {
        let path = temp_msp_path("oversized");
        // Write a header that claims a payload just above the limit.
        let header = MspHeader {
            magic: MSP_MAGIC,
            version: MSP_VERSION,
            entity_table_offset: 64,
            entity_count: 0,
            payload_section_offset: 64,
            payload_section_size: (MAX_MSP_SIZE + 1) as u32,
            checksum: [0u8; 32],
            _padding: [0; 8],
        };
        let mut file = std::fs::File::create(&path).unwrap();
        file.write_all(&header_as_bytes(&header)).unwrap();
        // Extend the file so mmap succeeds but the size check fires first.
        file.write_all(&[0u8; 65]).unwrap();
        file.flush().unwrap();
        drop(file);

        let result = MspMap::load(&path);
        assert!(matches!(result, Err(ERR_MSP_TOO_LARGE)));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn entity_table_overlap_header_rejected() {
        let path = temp_msp_path("layout_et_overlap");
        let header = MspHeader {
            magic: MSP_MAGIC,
            version: MSP_VERSION,
            entity_table_offset: 0, // Invalid: overlaps the header.
            entity_count: 1,
            payload_section_offset: 64,
            payload_section_size: ERROR_PAYLOAD_RESERVE as u32,
            checksum: [0u8; 32],
            _padding: [0; 8],
        };
        let mut file = std::fs::File::create(&path).unwrap();
        file.write_all(&header_as_bytes(&header)).unwrap();
        file.write_all(&[0u8; 128]).unwrap();
        file.flush().unwrap();
        drop(file);

        let result = MspMap::load(&path);
        assert!(matches!(result, Err(ERR_MSP_INVALID_LAYOUT)));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn payload_section_overlap_entity_table_rejected() {
        let path = temp_msp_path("layout_payload_overlap");
        // One descriptor makes the entity table span [64, 128).
        let header = MspHeader {
            magic: MSP_MAGIC,
            version: MSP_VERSION,
            entity_table_offset: 64,
            entity_count: 1,
            payload_section_offset: 64, // Invalid: before entity_table_end (128).
            payload_section_size: ERROR_PAYLOAD_RESERVE as u32,
            checksum: [0u8; 32],
            _padding: [0; 8],
        };
        let mut file = std::fs::File::create(&path).unwrap();
        file.write_all(&header_as_bytes(&header)).unwrap();
        file.write_all(&[0u8; 128]).unwrap();
        file.flush().unwrap();
        drop(file);

        let result = MspMap::load(&path);
        assert!(matches!(result, Err(ERR_MSP_INVALID_LAYOUT)));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn duplicate_entity_id_rejected() {
        let path = temp_msp_path("duplicate_id");
        let descriptors = vec![
            MspEntityDescriptor {
                entity_id: 0,
                payload_type_id: 0,
                tag_mask: 1,
                payload_offset: 0,
                payload_size: 64,
                _padding: [0; 40],
            },
            MspEntityDescriptor {
                entity_id: 0, // Duplicate.
                payload_type_id: 0,
                tag_mask: 2,
                payload_offset: 64,
                payload_size: 64,
                _padding: [0; 40],
            },
        ];
        let payload_section = vec![0u8; 128];
        write_msp_file(&path, &descriptors, &payload_section);

        let result = MspMap::load(&path);
        assert!(matches!(result, Err(ERR_MSP_DUPLICATE_ENTITY_ID)));

        let _ = std::fs::remove_file(&path);
    }
}

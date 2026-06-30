// Binary integrity verification, Ed25519 signature verification, and package
// extraction helpers.
use std::ffi::CStr;
use std::fs::File;
use std::os::raw::c_char;
use std::path::Path;

use crate::integrity_policy::{
    verify_sha256_file, IntegrityError, IntegrityPolicy, MAX_ZIP_COMPRESSION_RATIO,
    MAX_ZIP_ENTRIES, MAX_ZIP_UNCOMPRESSED_SIZE,
};
use zip::ZipArchive;

pub(crate) fn c_str_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: The caller guarantees `ptr` is a valid, NUL-terminated C string
    // for the lifetime of the call.
    unsafe { CStr::from_ptr(ptr).to_str().ok() }
}

// ---------------------------------------------------------------------------
// Binary integrity and package extraction.
// ---------------------------------------------------------------------------

/// Verifies that `filepath` hashes to `expected_sha` using streaming SHA-256.
///
/// `expected_sha` may be given with or without a leading `0x`/`0X` prefix and
/// is compared in constant time on the decoded bytes.
///
/// Files larger than `MAX_SHA_FILE_SIZE` are rejected.  Returns 0 on success,
/// non-zero on error.
pub fn verify_binary_integrity(filepath: *const c_char, expected_sha: *const c_char) -> i32 {
    let filepath_str = match c_str_to_str(filepath) {
        Some(s) => s,
        None => return -1,
    };
    let expected_sha_str = match c_str_to_str(expected_sha) {
        Some(s) => s,
        None => return -2,
    };

    match verify_sha256_file(Path::new(filepath_str), expected_sha_str) {
        Ok(()) => 0,
        Err(IntegrityError::HashMismatch) => 1,
        Err(IntegrityError::Io(_)) => -3,
        Err(IntegrityError::HexDecode(_)) => -4,
        Err(IntegrityError::InvalidHashLength { .. }) => -5,
        Err(IntegrityError::FileTooLarge { .. }) => -9,
        Err(_) => -6,
    }
}

/// Verifies an Ed25519 signature over the SHA-256 hash of the file at
/// `filepath`.
///
/// `signature_hex` and `public_key_hex` may be given with or without a leading
/// `0x`/`0X` prefix.  An empty or whitespace-only `public_key_hex` is rejected;
/// callers must supply a valid 32-byte Ed25519 public key.
///
/// Files larger than 256 MiB are rejected.  Returns 0 if the signature is
/// valid, non-zero otherwise.
pub fn verify_engine_signature(
    filepath: *const c_char,
    signature_hex: *const c_char,
    public_key_hex: *const c_char,
) -> i32 {
    let filepath_str = match c_str_to_str(filepath) {
        Some(s) => s,
        None => return -1,
    };
    let signature_hex_str = match c_str_to_str(signature_hex) {
        Some(s) => s,
        None => return -2,
    };
    let public_key_hex_str = match c_str_to_str(public_key_hex) {
        Some(s) => s,
        None => return -3,
    };

    if public_key_hex_str.trim().is_empty() {
        return -5;
    }

    let policy = match IntegrityPolicy::from_hex(public_key_hex_str) {
        Ok(p) => p,
        Err(IntegrityError::HexDecode(_)) => return -5,
        Err(IntegrityError::InvalidPublicKeyLength { .. }) => return -5,
        Err(_) => return -7,
    };

    match policy.verify_ed25519_signature(Path::new(filepath_str), signature_hex_str) {
        Ok(()) => 0,
        Err(IntegrityError::SignatureInvalid) => -10,
        Err(IntegrityError::HexDecode(_)) => -4,
        Err(IntegrityError::InvalidSignatureLength { .. }) => -6,
        Err(IntegrityError::Io(_)) => -8,
        Err(IntegrityError::FileTooLarge { .. }) => -11,
        Err(_) => -12,
    }
}

/// Extracts a ZIP archive to `output_dir` with strict safety limits.
///
/// Rejects symlinks/hardlinks, enforces a 1 GiB total uncompressed size, a
/// 100:1 compression ratio, and at most 10,000 entries.  Each entry must
/// resolve strictly inside `output_dir`.
pub fn extract_zip_package(zip_path: *const c_char, output_dir: *const c_char) -> i32 {
    let zip_path_str = match c_str_to_str(zip_path) {
        Some(s) => s,
        None => return -1,
    };
    let output_dir_str = match c_str_to_str(output_dir) {
        Some(s) => s,
        None => return -2,
    };

    let file = match File::open(zip_path_str) {
        Ok(f) => f,
        Err(_) => return -3,
    };

    let mut archive = match ZipArchive::new(file) {
        Ok(a) => a,
        Err(_) => return -4,
    };

    if archive.len() > MAX_ZIP_ENTRIES {
        return -12;
    }

    let dest_path = Path::new(output_dir_str);
    if !dest_path.exists() && std::fs::create_dir_all(dest_path).is_err() {
        return -5;
    }

    let canonical_dest = match std::fs::canonicalize(dest_path) {
        Ok(p) => p,
        Err(_) => dest_path.to_path_buf(),
    };

    let mut total_uncompressed: u64 = 0;
    let mut total_compressed: u64 = 0;

    for i in 0..archive.len() {
        let mut file = match archive.by_index(i) {
            Ok(f) => f,
            Err(_) => return -6,
        };

        // Reject symlinks and hardlinks represented as symlinks in the ZIP.
        if file.is_symlink() {
            return -13;
        }
        if let Some(mode) = file.unix_mode() {
            if mode & 0o170000 == 0o120000 {
                // S_IFLNK
                return -13;
            }
        }

        let outpath = match file.enclosed_name() {
            Some(path) => canonical_dest.join(path),
            None => return -14,
        };

        // Each entry must resolve strictly inside the destination directory.
        if !outpath.starts_with(&canonical_dest) {
            return -14;
        }

        total_uncompressed = total_uncompressed.saturating_add(file.size());
        total_compressed = total_compressed.saturating_add(file.compressed_size());

        if total_uncompressed > MAX_ZIP_UNCOMPRESSED_SIZE {
            return -15;
        }

        // Per-file ratio guard: a non-empty file with zero compressed size is
        // impossible in a legitimate archive and is treated as a zip bomb.
        if file.compressed_size() == 0 && file.size() > 0 {
            return -16;
        }
        if file.size()
            > file
                .compressed_size()
                .saturating_mul(MAX_ZIP_COMPRESSION_RATIO)
        {
            return -16;
        }

        // Total ratio guard.
        if total_compressed > 0
            && total_uncompressed > total_compressed.saturating_mul(MAX_ZIP_COMPRESSION_RATIO)
        {
            return -16;
        }

        if file.name().ends_with('/') {
            if std::fs::create_dir_all(&outpath).is_err() {
                return -7;
            }
        } else {
            if let Some(p) = outpath.parent() {
                if !p.exists() && std::fs::create_dir_all(p).is_err() {
                    return -8;
                }
            }
            let mut outfile = match File::create(&outpath) {
                Ok(f) => f,
                Err(_) => return -9,
            };
            if std::io::copy(&mut file, &mut outfile).is_err() {
                return -10;
            }
        }
    }

    0
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    use std::io::Write;

    #[test]
    fn test_verify_binary_integrity() {
        let temp_path = std::path::Path::new("temp_test_file.txt");
        let mut file = File::create(temp_path).unwrap();
        file.write_all(b"Malphas Engine Core Verification Data")
            .unwrap();
        drop(file);

        let mut hasher = Sha256::new();
        hasher.update(b"Malphas Engine Core Verification Data");
        let calculated_sha = format!("{:x}", hasher.finalize());

        let filepath_c = std::ffi::CString::new(temp_path.to_str().unwrap()).unwrap();
        let hash_c = std::ffi::CString::new(calculated_sha.as_str()).unwrap();

        let res = verify_binary_integrity(filepath_c.as_ptr(), hash_c.as_ptr());
        std::fs::remove_file(temp_path).unwrap();

        assert_eq!(res, 0);
    }

    #[test]
    fn test_verify_binary_integrity_0x_prefix() {
        let temp_path = std::path::Path::new("temp_test_file_0x.txt");
        std::fs::write(temp_path, b"prefix test").unwrap();

        let mut hasher = Sha256::new();
        hasher.update(b"prefix test");
        let calculated_sha = format!("0x{:x}", hasher.finalize());

        let filepath_c = std::ffi::CString::new(temp_path.to_str().unwrap()).unwrap();
        let hash_c = std::ffi::CString::new(calculated_sha.as_str()).unwrap();

        let res = verify_binary_integrity(filepath_c.as_ptr(), hash_c.as_ptr());
        std::fs::remove_file(temp_path).unwrap();

        assert_eq!(res, 0);
    }

    #[test]
    fn test_verify_binary_integrity_mismatch() {
        let temp_path = std::path::Path::new("temp_test_file_bad.txt");
        std::fs::write(temp_path, b"bad data").unwrap();

        let filepath_c = std::ffi::CString::new(temp_path.to_str().unwrap()).unwrap();
        let hash_c = std::ffi::CString::new(
            "0000000000000000000000000000000000000000000000000000000000000000",
        )
        .unwrap();

        let res = verify_binary_integrity(filepath_c.as_ptr(), hash_c.as_ptr());
        std::fs::remove_file(temp_path).unwrap();

        assert_eq!(res, 1);
    }

    #[test]
    fn test_verify_engine_signature_valid() {
        use ed25519_dalek::{Signer, SigningKey};
        use rand_core::OsRng;

        let temp_path = std::path::Path::new("temp_test_engine.bin");
        std::fs::write(temp_path, b"MALPHAS REINFORCED v2.2 Phase 6 engine").unwrap();

        let data = b"MALPHAS REINFORCED v2.2 Phase 6 engine";
        let hash = Sha256::digest(data);
        let signing_key = SigningKey::generate(&mut OsRng);
        let signature = signing_key.sign(&hash);
        let verifying_key = signing_key.verifying_key();

        let filepath_c = std::ffi::CString::new(temp_path.to_str().unwrap()).unwrap();
        let sig_hex = hex::encode(signature.to_bytes());
        let pk_hex = hex::encode(verifying_key.to_bytes());
        let sig_c = std::ffi::CString::new(sig_hex.as_str()).unwrap();
        let pk_c = std::ffi::CString::new(pk_hex.as_str()).unwrap();

        let res = verify_engine_signature(filepath_c.as_ptr(), sig_c.as_ptr(), pk_c.as_ptr());
        std::fs::remove_file(temp_path).unwrap();

        assert_eq!(res, 0);
    }

    #[test]
    fn test_verify_engine_signature_0x_prefix() {
        use ed25519_dalek::{Signer, SigningKey};
        use rand_core::OsRng;

        let temp_path = std::path::Path::new("temp_test_engine_0x.bin");
        std::fs::write(temp_path, b"prefix engine").unwrap();

        let hash = Sha256::digest(b"prefix engine");
        let signing_key = SigningKey::generate(&mut OsRng);
        let signature = signing_key.sign(&hash);

        let filepath_c = std::ffi::CString::new(temp_path.to_str().unwrap()).unwrap();
        let sig_hex = format!("0x{}", hex::encode(signature.to_bytes()));
        let pk_hex = format!("0X{}", hex::encode(signing_key.verifying_key().to_bytes()));
        let sig_c = std::ffi::CString::new(sig_hex.as_str()).unwrap();
        let pk_c = std::ffi::CString::new(pk_hex.as_str()).unwrap();

        let res = verify_engine_signature(filepath_c.as_ptr(), sig_c.as_ptr(), pk_c.as_ptr());
        std::fs::remove_file(temp_path).unwrap();

        assert_eq!(res, 0);
    }

    #[test]
    fn test_verify_engine_signature_invalid() {
        use ed25519_dalek::{Signer, SigningKey};
        use rand_core::OsRng;

        let temp_path = std::path::Path::new("temp_test_engine_tampered.bin");
        std::fs::write(temp_path, b"MALPHAS REINFORCED v2.2 Phase 6 engine").unwrap();

        let data = b"MALPHAS REINFORCED v2.2 Phase 6 engine";
        let hash = Sha256::digest(data);
        let signing_key = SigningKey::generate(&mut OsRng);
        let signature = signing_key.sign(&hash);
        let other_key = SigningKey::generate(&mut OsRng);

        let filepath_c = std::ffi::CString::new(temp_path.to_str().unwrap()).unwrap();
        let sig_hex = hex::encode(signature.to_bytes());
        let pk_hex = hex::encode(other_key.verifying_key().to_bytes());
        let sig_c = std::ffi::CString::new(sig_hex.as_str()).unwrap();
        let pk_c = std::ffi::CString::new(pk_hex.as_str()).unwrap();

        let res = verify_engine_signature(filepath_c.as_ptr(), sig_c.as_ptr(), pk_c.as_ptr());
        std::fs::remove_file(temp_path).unwrap();

        assert_ne!(res, 0);
    }

    #[test]
    fn test_verify_engine_signature_rejects_empty_public_key() {
        let temp_path = std::path::Path::new("temp_test_engine_empty_pk.bin");
        std::fs::write(temp_path, b"MALPHAS REINFORCED v2.2 Phase 6 engine").unwrap();

        let filepath_c = std::ffi::CString::new(temp_path.to_str().unwrap()).unwrap();
        let sig_c = std::ffi::CString::new("0".repeat(128)).unwrap();
        let pk_c = std::ffi::CString::new("").unwrap();

        let res = verify_engine_signature(filepath_c.as_ptr(), sig_c.as_ptr(), pk_c.as_ptr());
        std::fs::remove_file(temp_path).unwrap();

        assert_eq!(res, -5);
    }

    #[test]
    fn test_extract_zip_package_rejects_symlink() {
        let temp_dir =
            std::env::temp_dir().join(format!("malphas_zip_test_{}", std::process::id()));
        std::fs::create_dir_all(&temp_dir).unwrap();

        let zip_path = temp_dir.join("symlink.zip");
        let out_dir = temp_dir.join("out");

        let file = File::create(&zip_path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        zip.add_symlink(
            "link",
            "target.txt",
            zip::write::SimpleFileOptions::default(),
        )
        .unwrap();
        zip.finish().unwrap();

        let zip_c = std::ffi::CString::new(zip_path.to_str().unwrap()).unwrap();
        let out_c = std::ffi::CString::new(out_dir.to_str().unwrap()).unwrap();
        let res = extract_zip_package(zip_c.as_ptr(), out_c.as_ptr());

        let _ = std::fs::remove_dir_all(&temp_dir);
        assert_eq!(res, -13);
    }

    #[test]
    fn test_extract_zip_package_rejects_zip_bomb() {
        let temp_dir = std::env::temp_dir().join(format!("malphas_zb_test_{}", std::process::id()));
        std::fs::create_dir_all(&temp_dir).unwrap();

        let zip_path = temp_dir.join("bomb.zip");
        let out_dir = temp_dir.join("out");

        let file = File::create(&zip_path).unwrap();
        let mut zip = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        zip.start_file("bomb", options).unwrap();
        // A highly compressible 1 MiB buffer compresses to a few KiB, yielding
        // a ratio far above the 100:1 guard.
        let payload = vec![0u8; 1024 * 1024];
        zip.write_all(&payload).unwrap();
        zip.finish().unwrap();

        let zip_c = std::ffi::CString::new(zip_path.to_str().unwrap()).unwrap();
        let out_c = std::ffi::CString::new(out_dir.to_str().unwrap()).unwrap();
        let res = extract_zip_package(zip_c.as_ptr(), out_c.as_ptr());

        let _ = std::fs::remove_dir_all(&temp_dir);
        assert_eq!(res, -16);
    }
}

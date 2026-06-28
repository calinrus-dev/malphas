// Binary integrity verification, Ed25519 signature verification, and package
// extraction helpers.
use std::ffi::CStr;
use std::fs::File;
use std::io::Read;
use std::os::raw::c_char;

use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use sha2::{Digest, Sha256};
use zip::ZipArchive;

pub(crate) fn c_str_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr).to_str().ok() }
}

// ---------------------------------------------------------------------------
// Binary integrity and package extraction.
// ---------------------------------------------------------------------------
pub fn verify_binary_integrity(filepath: *const c_char, expected_sha: *const c_char) -> i32 {
    let filepath_str = match c_str_to_str(filepath) {
        Some(s) => s,
        None => return -1,
    };
    let expected_sha_str = match c_str_to_str(expected_sha) {
        Some(s) => s,
        None => return -2,
    };

    let clean_expected = expected_sha_str.trim_start_matches("0x").to_lowercase();

    let mut file = match File::open(filepath_str) {
        Ok(f) => f,
        Err(_) => return -3,
    };

    let mut hasher = Sha256::new();
    let mut buffer = [0; 8192];
    loop {
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => hasher.update(&buffer[..n]),
            Err(_) => return -4,
        }
    }
    let calculated_sha = format!("{:x}", hasher.finalize());

    if calculated_sha == clean_expected {
        0
    } else {
        1
    }
}

/// Verifies an Ed25519 signature over the file at `filepath`.
///
/// `signature_hex` and `public_key_hex` must be lower-case ASCII hex strings
/// representing a 64-byte signature and a 32-byte public key respectively.
/// Returns 0 if the signature is valid, non-zero otherwise.
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

    let signature_bytes = match hex::decode(signature_hex_str.trim()) {
        Ok(b) if b.len() == 64 => b,
        _ => return -4,
    };
    let public_key_bytes: [u8; 32] = match hex::decode(public_key_hex_str.trim()) {
        Ok(b) if b.len() == 32 => {
            let mut arr = [0u8; 32];
            arr.copy_from_slice(&b);
            arr
        }
        _ => return -5,
    };

    let signature = match Signature::from_slice(&signature_bytes) {
        Ok(s) => s,
        Err(_) => return -6,
    };
    let public_key = match VerifyingKey::from_bytes(&public_key_bytes) {
        Ok(k) => k,
        Err(_) => return -7,
    };

    let mut file = match File::open(filepath_str) {
        Ok(f) => f,
        Err(_) => return -8,
    };

    let mut message = Vec::new();
    if file.read_to_end(&mut message).is_err() {
        return -9;
    }

    match public_key.verify(&message, &signature) {
        Ok(_) => 0,
        Err(_) => -10,
    }
}

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

    let dest_path = std::path::Path::new(output_dir_str);
    if !dest_path.exists() && std::fs::create_dir_all(dest_path).is_err() {
        return -5;
    }

    for i in 0..archive.len() {
        let mut file = match archive.by_index(i) {
            Ok(f) => f,
            Err(_) => return -6,
        };

        let outpath = match file.enclosed_name() {
            Some(path) => dest_path.join(path),
            None => continue,
        };

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
    fn test_verify_engine_signature_valid() {
        use ed25519_dalek::{Signer, SigningKey};
        use rand_core::OsRng;

        let temp_path = std::path::Path::new("temp_test_engine.bin");
        std::fs::write(temp_path, b"MALPHAS REINFORCED v2.2 Phase 6 engine").unwrap();

        let data = b"MALPHAS REINFORCED v2.2 Phase 6 engine";
        let signing_key = SigningKey::generate(&mut OsRng);
        let signature = signing_key.sign(data);
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
    fn test_verify_engine_signature_invalid() {
        use ed25519_dalek::{Signer, SigningKey};
        use rand_core::OsRng;

        let temp_path = std::path::Path::new("temp_test_engine_tampered.bin");
        std::fs::write(temp_path, b"MALPHAS REINFORCED v2.2 Phase 6 engine").unwrap();

        let data = b"MALPHAS REINFORCED v2.2 Phase 6 engine";
        let signing_key = SigningKey::generate(&mut OsRng);
        let signature = signing_key.sign(data);
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
}

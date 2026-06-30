// Centralized binary integrity and Ed25519 signature verification policy.
//
// This module is the single place where the core decides whether a file on disk
// matches an expected SHA-256 digest or a side-car Ed25519 signature.  All
// checks use constant-time comparison where feasible, and all file reads are
// streamed so the core never holds the entire payload in memory at once.

use std::fs::File;
use std::io::{self, Read};
use std::path::Path;
use std::sync::OnceLock;

use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

static GLOBAL_TRUST_ANCHOR: OnceLock<IntegrityPolicy> = OnceLock::new();

/// Set the global Ed25519 trust anchor used for `.msp` and `.mxc` signature
/// verification.  Must be called before the first signed load if the default
/// test anchor is not acceptable.
pub fn set_global_trust_anchor(public_key_hex: &str) -> Result<(), IntegrityError> {
    let policy = IntegrityPolicy::from_hex(public_key_hex)?;
    GLOBAL_TRUST_ANCHOR
        .set(policy)
        .map_err(|_| IntegrityError::SignatureInvalid)
}

/// Return the configured global trust anchor, falling back to the test anchor.
pub fn global_trust_anchor() -> &'static IntegrityPolicy {
    GLOBAL_TRUST_ANCHOR.get_or_init(|| {
        IntegrityPolicy::default_trust_anchor().expect("built-in test trust anchor is valid hex")
    })
}

/// Maximum file size that the streaming Ed25519 verifier will hash.  Files
/// larger than this are rejected to avoid unbounded work on malicious inputs.
pub const MAX_SIGNATURE_FILE_SIZE: u64 = 256 * 1024 * 1024;

/// Hard cap on the number of entries the ZIP extractor will process.
pub const MAX_ZIP_ENTRIES: usize = 10_000;

/// Hard cap on total uncompressed bytes extracted from a ZIP archive.
pub const MAX_ZIP_UNCOMPRESSED_SIZE: u64 = 1024 * 1024 * 1024;

/// Maximum acceptable compression ratio (uncompressed:compressed) for a ZIP
/// archive.  Anything higher is treated as a zip-bomb attempt.
pub const MAX_ZIP_COMPRESSION_RATIO: u64 = 100;

/// Test-only trust anchor.  This is NOT a production key and must be replaced
/// by a real release-signing key before any binary is shipped.
///
/// The corresponding secret key is intentionally omitted from the repository.
const DEFAULT_TRUST_ANCHOR_HEX: &str =
    "aac8adcae7707a961bd03e24c1196d2593ba62f491ab00c0dd20bfa9b284aa1c";

/// Errors that can occur while applying the integrity policy.
#[derive(Debug)]
pub enum IntegrityError {
    Io(io::Error),
    HexDecode(hex::FromHexError),
    InvalidHashLength { expected: usize, got: usize },
    InvalidSignatureLength { expected: usize, got: usize },
    InvalidPublicKeyLength { expected: usize, got: usize },
    FileTooLarge { max: u64, got: u64 },
    HashMismatch,
    SignatureInvalid,
}

/// Verifies file integrity using SHA-256 and Ed25519.
///
/// The policy owns the public key (trust anchor) that signatures are checked
/// against.  Callers can construct a policy from a hex public key or use the
/// default test-only anchor.
pub struct IntegrityPolicy {
    public_key: VerifyingKey,
}

impl IntegrityPolicy {
    /// Build a policy from an already validated Ed25519 verifying key.
    #[allow(dead_code)]
    pub fn new(public_key: VerifyingKey) -> Self {
        Self { public_key }
    }

    /// Build a policy from a 32-byte Ed25519 public key given as lower/upper
    /// case ASCII hex, optionally prefixed with `0x` or `0X`.
    pub fn from_hex(public_key_hex: &str) -> Result<Self, IntegrityError> {
        let hex = public_key_hex
            .trim()
            .trim_start_matches("0x")
            .trim_start_matches("0X");
        let bytes = hex::decode(hex).map_err(IntegrityError::HexDecode)?;
        if bytes.len() != 32 {
            return Err(IntegrityError::InvalidPublicKeyLength {
                expected: 32,
                got: bytes.len(),
            });
        }
        let key: [u8; 32] = bytes.try_into().unwrap();
        let public_key =
            VerifyingKey::from_bytes(&key).map_err(|_| IntegrityError::SignatureInvalid)?;
        Ok(Self { public_key })
    }

    /// Returns the test-only trust anchor documented on `DEFAULT_TRUST_ANCHOR_HEX`.
    pub fn default_trust_anchor() -> Result<Self, IntegrityError> {
        Self::from_hex(DEFAULT_TRUST_ANCHOR_HEX)
    }

    /// Borrow the configured verifying key.
    #[allow(dead_code)]
    pub fn public_key(&self) -> &VerifyingKey {
        &self.public_key
    }

    /// Verify that `path` hashes to `expected_hex` using streaming SHA-256.
    ///
    /// The comparison is performed in constant time on the decoded bytes to
    /// avoid leaking information through a timing side channel.
    pub fn verify_sha256(&self, path: &Path, expected_hex: &str) -> Result<(), IntegrityError> {
        let expected_hex = expected_hex
            .trim()
            .trim_start_matches("0x")
            .trim_start_matches("0X");
        let expected = hex::decode(expected_hex).map_err(IntegrityError::HexDecode)?;
        if expected.len() != 32 {
            return Err(IntegrityError::InvalidHashLength {
                expected: 32,
                got: expected.len(),
            });
        }

        let mut file = File::open(path).map_err(IntegrityError::Io)?;
        let mut hasher = Sha256::new();
        let mut buffer = [0u8; 8192];
        loop {
            match file.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => hasher.update(&buffer[..n]),
                Err(e) => return Err(IntegrityError::Io(e)),
            }
        }
        let actual = hasher.finalize();

        if actual[..].ct_eq(&expected).unwrap_u8() == 1 {
            Ok(())
        } else {
            Err(IntegrityError::HashMismatch)
        }
    }

    /// Verify an Ed25519 sidecar signature over the SHA-256 hash of `path`.
    ///
    /// The file is read in chunks and hashed with SHA-256.  Files larger than
    /// `MAX_SIGNATURE_FILE_SIZE` are rejected.  The signature bytes (hex, with
    /// optional `0x`/`0X` prefix) are then verified against the resulting hash
    /// using the policy's trust anchor.
    pub fn verify_ed25519_signature(
        &self,
        path: &Path,
        signature_hex: &str,
    ) -> Result<(), IntegrityError> {
        let signature_hex = signature_hex
            .trim()
            .trim_start_matches("0x")
            .trim_start_matches("0X");
        let signature_bytes = hex::decode(signature_hex).map_err(IntegrityError::HexDecode)?;
        if signature_bytes.len() != 64 {
            return Err(IntegrityError::InvalidSignatureLength {
                expected: 64,
                got: signature_bytes.len(),
            });
        }
        let signature = Signature::from_slice(&signature_bytes)
            .map_err(|_| IntegrityError::SignatureInvalid)?;

        let mut file = File::open(path).map_err(IntegrityError::Io)?;
        let mut hasher = Sha256::new();
        let mut buffer = [0u8; 8192];
        let mut total_read: u64 = 0;
        loop {
            match file.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => {
                    total_read += n as u64;
                    if total_read > MAX_SIGNATURE_FILE_SIZE {
                        return Err(IntegrityError::FileTooLarge {
                            max: MAX_SIGNATURE_FILE_SIZE,
                            got: total_read,
                        });
                    }
                    hasher.update(&buffer[..n]);
                }
                Err(e) => return Err(IntegrityError::Io(e)),
            }
        }
        let message_hash = hasher.finalize();

        self.public_key
            .verify(&message_hash, &signature)
            .map_err(|_| IntegrityError::SignatureInvalid)
    }
}

impl Default for IntegrityPolicy {
    fn default() -> Self {
        Self::default_trust_anchor().expect("built-in test trust anchor is valid hex")
    }
}

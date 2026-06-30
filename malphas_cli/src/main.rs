//! Malphas package compiler and signer CLI (v2.9.0).
//!
//! Subcommands:
//!   compile <manifest.json>  -- Build <pack_id>.msp and generate bindings.rs
//!   sign    <file>           -- Write <file>.sig using a signing key from
//!                               MALPHAS_SIGNING_KEY, --signing-key-env,
//!                               --signing-key-file, or stdin
//!   pubkey  <file>           -- Print the Ed25519 public key for a signing key
//!                               from MALPHAS_SIGNING_KEY, --signing-key-env,
//!                               --signing-key-file, or stdin

mod bindings_codegen;
mod compiler;
mod manifest;

use clap::{Parser, Subcommand};
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};
use std::error::Error;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::bindings_codegen::generate_bindings_next_to_manifest;
use crate::compiler::compile_manifest;
use crate::manifest::Manifest;

#[derive(Parser)]
#[command(
    name = "malphas-cli",
    version,
    about = "Malphas workspace compiler and signer"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Compile a workspace manifest into a .msp package and bindings.rs.
    Compile {
        /// Path to manifest.json
        manifest: PathBuf,
    },
    /// Sign a file with an Ed25519 private key.
    Sign {
        /// File to sign
        file: PathBuf,
        /// Read the 32-byte Ed25519 private key from this environment variable.
        /// Falls back to MALPHAS_SIGNING_KEY when neither source is provided.
        #[arg(long, value_name = "VAR")]
        signing_key_env: Option<String>,
        /// Read the 32-byte Ed25519 private key from this file (use `-` for stdin).
        #[arg(long, value_name = "PATH")]
        signing_key_file: Option<PathBuf>,
    },
    /// Print the Ed25519 public key for a private key.
    Pubkey {
        /// Read the 32-byte Ed25519 private key from this environment variable.
        /// Falls back to MALPHAS_SIGNING_KEY when neither source is provided.
        #[arg(long, value_name = "VAR")]
        signing_key_env: Option<String>,
        /// Read the 32-byte Ed25519 private key from this file (use `-` for stdin).
        #[arg(long, value_name = "PATH")]
        signing_key_file: Option<PathBuf>,
    },
}

fn main() {
    let cli = Cli::parse();
    match cli.command {
        Commands::Compile { manifest } => {
            if let Err(e) = compile_workspace(&manifest) {
                eprintln!("Compile failed: {e}");
                std::process::exit(1);
            }
        }
        Commands::Sign {
            file,
            signing_key_env,
            signing_key_file,
        } => {
            if let Err(e) = sign_file_cli(&file, signing_key_env, signing_key_file) {
                eprintln!("Sign failed: {e}");
                std::process::exit(1);
            }
        }
        Commands::Pubkey {
            signing_key_env,
            signing_key_file,
        } => {
            if let Err(e) = print_public_key_cli(signing_key_env, signing_key_file) {
                eprintln!("Pubkey failed: {e}");
                std::process::exit(1);
            }
        }
    }
}

/// Compile a manifest into `.msp` and generate `bindings.rs` next to it.
fn compile_workspace(manifest_path: &Path) -> Result<(), Box<dyn Error>> {
    let manifest_dir = manifest_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));

    let manifest_text = fs::read_to_string(manifest_path)
        .map_err(|e| format!("failed to read manifest '{}': {e}", manifest_path.display()))?;
    let manifest: Manifest = serde_json::from_str(&manifest_text)
        .map_err(|e| format!("invalid manifest '{}': {e}", manifest_path.display()))?;

    compiler::validate_pack_id(&manifest.pack_id)?;

    compile_manifest(manifest_path)?;
    generate_bindings_next_to_manifest(&manifest, manifest_dir)?;

    Ok(())
}

fn resolve_signing_key(
    env_var: Option<String>,
    file_path: Option<PathBuf>,
) -> Result<String, Box<dyn Error>> {
    if let Some(var) = env_var {
        let value = std::env::var(&var).map_err(|e| {
            format!("failed to read signing key from environment variable `{var}`: {e}")
        })?;
        return Ok(value);
    }

    if let Some(path) = file_path {
        let mut key = String::new();
        if path.as_os_str() == "-" {
            std::io::stdin()
                .read_to_string(&mut key)
                .map_err(|e| format!("failed to read signing key from stdin: {e}"))?;
        } else {
            let mut file = fs::File::open(&path).map_err(|e| {
                format!("failed to open signing key file '{}': {e}", path.display())
            })?;
            file.read_to_string(&mut key).map_err(|e| {
                format!("failed to read signing key file '{}': {e}", path.display())
            })?;
        }
        return Ok(key);
    }

    // Default fallback when no explicit source is provided.
    let default_var = "MALPHAS_SIGNING_KEY";
    std::env::var(default_var).map_err(|e| {
        format!("failed to read signing key from default environment variable `{default_var}`: {e}")
            .into()
    })
}

fn decode_hex_32(s: &str) -> Result<[u8; 32], Box<dyn Error>> {
    let cleaned = s.trim().trim_start_matches("0x").trim_start_matches("0X");
    let bytes = hex::decode(cleaned)?;
    if bytes.len() != 32 {
        return Err("Invalid private key: expected 64 hex characters".into());
    }
    let mut array = [0u8; 32];
    array.copy_from_slice(&bytes);
    Ok(array)
}

fn signing_key_from_source(
    env_var: Option<String>,
    file_path: Option<PathBuf>,
) -> Result<SigningKey, Box<dyn Error>> {
    let key_hex = resolve_signing_key(env_var, file_path)?;
    if key_hex.trim().is_empty() {
        return Err("empty signing key; use a valid 32-byte Ed25519 seed".into());
    }
    let seed = decode_hex_32(&key_hex)?;
    Ok(SigningKey::from_bytes(&seed))
}

fn sign_file_cli(
    file_path: &Path,
    env_var: Option<String>,
    file_key_path: Option<PathBuf>,
) -> Result<(), Box<dyn Error>> {
    let signing_key = signing_key_from_source(env_var, file_key_path)?;
    sign_file_with_key(file_path, &signing_key)
}

fn sign_file_with_key(file_path: &Path, signing_key: &SigningKey) -> Result<(), Box<dyn Error>> {
    let data = fs::read(file_path)?;
    let hash = Sha256::digest(&data);
    let signature = signing_key.sign(&hash);

    let sig_path = file_path.with_extension(
        file_path
            .extension()
            .and_then(|ext| ext.to_str())
            .map_or_else(|| "sig".to_string(), |ext| format!("{ext}.sig")),
    );
    fs::write(&sig_path, hex::encode(signature.to_bytes()))?;
    println!("Signature written to {}", sig_path.display());
    Ok(())
}

fn print_public_key_cli(
    env_var: Option<String>,
    file_path: Option<PathBuf>,
) -> Result<(), Box<dyn Error>> {
    let signing_key = signing_key_from_source(env_var, file_path)?;
    let public_key: VerifyingKey = signing_key.verifying_key();
    println!("{}", hex::encode(public_key.to_bytes()));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::Mutex;

    /// Serializes tests that manipulate `MALPHAS_SIGNING_KEY` because
    /// `std::env::var` is process-global and tests run in parallel by default.
    static SIGNING_KEY_ENV_LOCK: Mutex<()> = Mutex::new(());

    fn temp_dir() -> std::path::PathBuf {
        std::env::temp_dir().join(format!("malphas_cli_test_{}", std::process::id()))
    }

    #[test]
    fn sign_command_writes_verifiable_signature() {
        use ed25519_dalek::{Verifier, VerifyingKey};
        use rand_core::OsRng;

        let tmp_dir = temp_dir().join("signature");
        fs::create_dir_all(&tmp_dir).unwrap();

        let data_path = tmp_dir.join("payload.bin");
        fs::write(&data_path, b"MALPHAS CLI SIGN TEST").unwrap();

        let signing_key = SigningKey::generate(&mut OsRng);

        sign_file_with_key(&data_path, &signing_key).unwrap();

        let sig_path = data_path.with_extension("bin.sig");
        assert!(sig_path.exists());

        let sig_hex = fs::read_to_string(&sig_path).unwrap();
        let sig_bytes = hex::decode(sig_hex.trim()).unwrap();
        let signature = ed25519_dalek::Signature::from_slice(&sig_bytes).unwrap();

        let verifying_key =
            VerifyingKey::from_bytes(&signing_key.verifying_key().to_bytes()).unwrap();
        let data = fs::read(&data_path).unwrap();
        let hash = Sha256::digest(&data);
        assert!(verifying_key.verify(&hash, &signature).is_ok());

        let _ = fs::remove_file(&data_path);
        let _ = fs::remove_file(&sig_path);
        let _ = fs::remove_dir(&tmp_dir);
    }

    #[test]
    fn sign_command_accepts_key_from_env_variable() {
        use rand_core::OsRng;

        let tmp_dir = temp_dir().join("env");
        fs::create_dir_all(&tmp_dir).unwrap();

        let data_path = tmp_dir.join("payload.bin");
        fs::write(&data_path, b"MALPHAS CLI SIGN ENV TEST").unwrap();

        let signing_key = SigningKey::generate(&mut OsRng);
        let env_var = "MALPHAS_TEST_SIGNING_KEY_ENV";
        std::env::set_var(env_var, hex::encode(signing_key.to_bytes()));

        sign_file_cli(&data_path, Some(env_var.to_string()), None).unwrap();

        assert!(data_path.with_extension("bin.sig").exists());

        let _ = fs::remove_file(&data_path);
        let _ = fs::remove_file(data_path.with_extension("bin.sig"));
        let _ = fs::remove_dir(&tmp_dir);
    }

    #[test]
    fn sign_command_accepts_key_from_file() {
        use rand_core::OsRng;

        let tmp_dir = temp_dir().join("file");
        fs::create_dir_all(&tmp_dir).unwrap();

        let data_path = tmp_dir.join("payload.bin");
        fs::write(&data_path, b"MALPHAS CLI SIGN FILE TEST").unwrap();

        let signing_key = SigningKey::generate(&mut OsRng);
        let key_path = tmp_dir.join("key.hex");
        fs::write(
            &key_path,
            format!("0x{}", hex::encode(signing_key.to_bytes())),
        )
        .unwrap();

        sign_file_cli(&data_path, None, Some(key_path.clone())).unwrap();

        assert!(data_path.with_extension("bin.sig").exists());

        let _ = fs::remove_file(&data_path);
        let _ = fs::remove_file(data_path.with_extension("bin.sig"));
        let _ = fs::remove_file(&key_path);
        let _ = fs::remove_dir(&tmp_dir);
    }

    #[test]
    fn sign_command_rejects_missing_key_source() {
        let _guard = SIGNING_KEY_ENV_LOCK.lock().unwrap();
        let tmp_dir = temp_dir().join("missing");
        fs::create_dir_all(&tmp_dir).unwrap();

        let data_path = tmp_dir.join("payload.bin");
        fs::write(&data_path, b"MALPHAS CLI SIGN MISSING TEST").unwrap();

        // Ensure the default env var is absent so the fallback fails cleanly.
        std::env::remove_var("MALPHAS_SIGNING_KEY");

        let result = sign_file_cli(&data_path, None, None);
        assert!(result.is_err());

        let _ = fs::remove_file(&data_path);
        let _ = fs::remove_dir(&tmp_dir);
    }

    #[test]
    fn sign_command_rejects_empty_signing_key() {
        let tmp_dir = temp_dir().join("empty_key");
        fs::create_dir_all(&tmp_dir).unwrap();

        let data_path = tmp_dir.join("payload.bin");
        fs::write(&data_path, b"MALPHAS CLI SIGN EMPTY TEST").unwrap();

        let env_var = "MALPHAS_TEST_EMPTY_SIGNING_KEY";
        std::env::set_var(env_var, "   ");

        let result = sign_file_cli(&data_path, Some(env_var.to_string()), None);
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("empty signing key"));

        std::env::remove_var(env_var);
        let _ = fs::remove_file(&data_path);
        let _ = fs::remove_dir(&tmp_dir);
    }

    #[test]
    fn sign_command_uses_default_malphas_signing_key() {
        let _guard = SIGNING_KEY_ENV_LOCK.lock().unwrap();
        use rand_core::OsRng;

        let tmp_dir = temp_dir().join("default_env");
        fs::create_dir_all(&tmp_dir).unwrap();

        let data_path = tmp_dir.join("payload.bin");
        fs::write(&data_path, b"MALPHAS CLI SIGN DEFAULT TEST").unwrap();

        let signing_key = SigningKey::generate(&mut OsRng);
        std::env::set_var("MALPHAS_SIGNING_KEY", hex::encode(signing_key.to_bytes()));

        sign_file_cli(&data_path, None, None).unwrap();

        assert!(data_path.with_extension("bin.sig").exists());

        std::env::remove_var("MALPHAS_SIGNING_KEY");
        let _ = fs::remove_file(&data_path);
        let _ = fs::remove_file(data_path.with_extension("bin.sig"));
        let _ = fs::remove_dir(&tmp_dir);
    }

    #[test]
    fn pubkey_command_prints_matching_public_key() {
        use rand_core::OsRng;

        let signing_key = SigningKey::generate(&mut OsRng);
        let expected = hex::encode(signing_key.verifying_key().to_bytes());

        let key_path =
            std::env::temp_dir().join(format!("malphas_cli_pubkey_key_{}.hex", std::process::id()));
        fs::write(&key_path, hex::encode(signing_key.to_bytes())).unwrap();

        let mut output = Vec::new();
        {
            let signing_key = signing_key_from_source(None, Some(key_path.clone())).unwrap();
            let public_key = signing_key.verifying_key();
            output.extend_from_slice(hex::encode(public_key.to_bytes()).as_bytes());
        }

        assert_eq!(String::from_utf8(output).unwrap().trim(), expected);

        let _ = fs::remove_file(&key_path);
    }

    #[test]
    fn compile_command_rejects_unknown_manifest_fields() {
        let tmp_dir =
            std::env::temp_dir().join(format!("malphas_cli_manifest_test_{}", std::process::id()));
        fs::create_dir_all(&tmp_dir).unwrap();

        let manifest_path = tmp_dir.join("manifest.json");
        let mut file = fs::File::create(&manifest_path).unwrap();
        file.write_all(br#"{"pack_id":"x","entities":[],"extra":true}"#)
            .unwrap();
        file.flush().unwrap();
        drop(file);

        let result = compile_workspace(&manifest_path);
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("unknown field") || msg.contains("invalid manifest"));

        let _ = fs::remove_file(&manifest_path);
        let _ = fs::remove_dir(&tmp_dir);
    }
}

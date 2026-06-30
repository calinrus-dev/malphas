//! Malphas package compiler and signer CLI (v2.7.0).
//!
//! Subcommands:
//!   compile <manifest.json>  -- Build <pack_id>.msp and generate bindings.rs
//!   sign    <file> <privkey> -- Write <file>.sig

mod bindings_codegen;
mod compiler;
mod manifest;

use clap::{Parser, Subcommand};
use ed25519_dalek::{Signer, SigningKey};
use std::error::Error;
use std::fs;
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
        /// 32-byte Ed25519 private key as hex
        private_key_hex: String,
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
            private_key_hex,
        } => {
            if let Err(e) = sign_file(&file, &private_key_hex) {
                eprintln!("Sign failed: {e}");
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

fn sign_file(file_path: &Path, private_key_hex: &str) -> Result<(), Box<dyn Error>> {
    if private_key_hex.trim().is_empty() {
        return Err(format!(
            "empty signing key for '{}'; use a valid 32-byte Ed25519 seed",
            file_path.display()
        )
        .into());
    }

    let seed = decode_hex_32(private_key_hex)?;
    let signing_key = SigningKey::from_bytes(&seed);

    let data = fs::read(file_path)?;
    let signature = signing_key.sign(&data);

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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn sign_command_writes_verifiable_signature() {
        use ed25519_dalek::{Verifier, VerifyingKey};
        use rand_core::OsRng;

        let tmp_dir =
            std::env::temp_dir().join(format!("malphas_cli_sign_test_{}", std::process::id()));
        fs::create_dir_all(&tmp_dir).unwrap();

        let data_path = tmp_dir.join("payload.bin");
        fs::write(&data_path, b"MALPHAS CLI SIGN TEST").unwrap();

        let signing_key = SigningKey::generate(&mut OsRng);
        let private_key_hex = hex::encode(signing_key.to_bytes());

        sign_file(&data_path, &private_key_hex).unwrap();

        let sig_path = data_path.with_extension("bin.sig");
        assert!(sig_path.exists());

        let sig_hex = fs::read_to_string(&sig_path).unwrap();
        let sig_bytes = hex::decode(sig_hex.trim()).unwrap();
        let signature = ed25519_dalek::Signature::from_slice(&sig_bytes).unwrap();

        let verifying_key =
            VerifyingKey::from_bytes(&signing_key.verifying_key().to_bytes()).unwrap();
        let data = fs::read(&data_path).unwrap();
        assert!(verifying_key.verify(&data, &signature).is_ok());

        // 0x prefix must also be accepted.
        let data_path_0x = tmp_dir.join("payload_0x.bin");
        fs::write(&data_path_0x, b"MALPHAS CLI SIGN TEST 0X").unwrap();
        sign_file(&data_path_0x, &format!("0x{private_key_hex}")).unwrap();
        let sig_path_0x = data_path_0x.with_extension("bin.sig");
        assert!(sig_path_0x.exists());

        // Empty key must be rejected.
        let empty_result = sign_file(&data_path, "");
        assert!(empty_result.is_err());

        let _ = fs::remove_file(&data_path);
        let _ = fs::remove_file(&sig_path);
        let _ = fs::remove_file(&data_path_0x);
        let _ = fs::remove_file(&sig_path_0x);
        let _ = fs::remove_dir(&tmp_dir);
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

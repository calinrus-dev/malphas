//! Developer-tooling commands: key generation, signature verification,
//! workspace scaffolding, and system builds.

use ed25519_dalek::{Signer, Verifier, VerifyingKey};
use rand_core::OsRng;
use sha2::{Digest, Sha256};
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::signing_key_from_source;

const DEFAULT_WORDLIST: [&str; 480] = include!("wordlist.rs");

/// Generates a fresh Ed25519 keypair, writes the private seed to disk, and
/// prints the public key.
pub fn keygen(output_dir: &Path, with_seed_phrase: bool) -> Result<(), Box<dyn Error>> {
    if !output_dir.exists() {
        fs::create_dir_all(output_dir)?;
    }

    let signing_key = ed25519_dalek::SigningKey::generate(&mut OsRng);
    let verifying_key = signing_key.verifying_key();

    let private_hex = hex::encode(signing_key.to_bytes());
    let public_hex = hex::encode(verifying_key.to_bytes());

    let private_path = output_dir.join("malphas_signing_key.hex");
    let public_path = output_dir.join("malphas_signing_key.pub");

    fs::write(&private_path, format!("0x{private_hex}\n"))?;
    fs::write(&public_path, format!("{public_hex}\n"))?;

    println!("Private key written to {}", private_path.display());
    println!("Public key:  {public_hex}");
    println!("Public key written to {}", public_path.display());

    if with_seed_phrase {
        let phrase = seed_phrase_from_seed(signing_key.to_bytes());
        let phrase_path = output_dir.join("malphas_signing_key.seed.txt");
        fs::write(&phrase_path, format!("{phrase}\n"))?;
        println!("Seed phrase written to {}", phrase_path.display());
        println!(
            "WARNING: the generated phrase is a Malphas-local mnemonic, not a BIP-39 wallet seed."
        );
    }

    Ok(())
}

/// Verifies a sidecar signature against a public key.
pub fn verify(
    file: &Path,
    public_key_source: &str,
) -> Result<(), Box<dyn Error>> {
    let public_hex = if Path::new(public_key_source).exists() {
        fs::read_to_string(public_key_source)?
    } else {
        public_key_source.to_string()
    };
    let public_hex = public_hex.trim().trim_start_matches("0x").trim_start_matches("0X");
    let public_bytes = hex::decode(public_hex)
        .map_err(|e| format!("invalid public key hex: {e}"))?;
    if public_bytes.len() != 32 {
        return Err("public key must be 32 bytes".into());
    }
    let mut array = [0u8; 32];
    array.copy_from_slice(&public_bytes);
    let verifying_key = VerifyingKey::from_bytes(&array)
        .map_err(|_| "invalid Ed25519 public key")?;

    let sig_path = file.with_extension(
        file.extension()
            .and_then(|ext| ext.to_str())
            .map_or_else(|| "sig".to_string(), |ext| format!("{ext}.sig")),
    );
    if !sig_path.exists() {
        return Err(format!("signature file not found: {}", sig_path.display()).into());
    }
    let sig_hex = fs::read_to_string(&sig_path)?;
    let sig_hex = sig_hex.trim().trim_start_matches("0x").trim_start_matches("0X");
    let sig_bytes = hex::decode(sig_hex)
        .map_err(|e| format!("invalid signature hex: {e}"))?;
    let signature = ed25519_dalek::Signature::from_slice(&sig_bytes)
        .map_err(|_| "invalid Ed25519 signature")?;

    let data = fs::read(file)?;
    let hash = Sha256::digest(&data);

    verifying_key
        .verify(&hash, &signature)
        .map_err(|_| "signature verification failed")?;

    println!("Signature for {} is valid.", file.display());
    Ok(())
}

/// Creates a minimal template workspace with a package manifest and a Rust
/// system crate ready to compile.
pub fn init_workspace(
    name: &str,
    dir: &Path,
) -> Result<(), Box<dyn Error>> {
    if dir.exists() && dir.read_dir()?.next().is_some() {
        return Err(format!("directory {} is not empty", dir.display()).into());
    }
    fs::create_dir_all(dir)?;

    let pack_id = sanitize_id(name);
    let systems_dir = dir.join("systems").join(&pack_id);
    fs::create_dir_all(&systems_dir)?;

    let cargo_toml = format!(
        r#"[package]
name = "{pack_id}"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
"#
    );
    fs::write(systems_dir.join("Cargo.toml"), cargo_toml)?;
    fs::create_dir_all(systems_dir.join("src"))?;

    let lib_rs = r#"//! Malphas system template.

/// 64-byte ABI mirror of the core `DartRenderCommand`.
#[repr(C, align(64))]
#[derive(Clone, Copy)]
pub struct DartRenderCommand {
    pub cmd_type: u32,
    pub entity_id: u32,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub color: u32,
    pub payload_id: u32,
    pub _padding: [u32; 8],
}

#[no_mangle]
pub extern "C" fn malphas_init_system(
    _lookup_table: *const *const u8,
    _entity_count: u32,
) -> i32 {
    0
}

#[no_mangle]
pub extern "C" fn malphas_tick(
    _lookup_table: *const *const u8,
    entity_count: u32,
    _dt_micros: u64,
    render_buffer: *mut DartRenderCommand,
    render_capacity: u32,
    render_count: *mut u32,
) {
    if render_buffer.is_null() || render_count.is_null() {
        return;
    }
    let count = (entity_count as usize).min(render_capacity as usize);
    for id in 0..count {
        let cmd = unsafe { &mut *render_buffer.add(id) };
        cmd.cmd_type = 1; // rectangle
        cmd.entity_id = id as u32;
        cmd.x = 100.0;
        cmd.y = 100.0;
        cmd.width = 50.0;
        cmd.height = 50.0;
        cmd.color = 0xFF00FFCC;
        cmd.payload_id = 0;
        cmd._padding = [0; 8];
    }
    unsafe {
        *render_count = count as u32;
    }
}
"#;
    fs::write(systems_dir.join("src").join("lib.rs"), lib_rs)?;

    let manifest = format!(
        r#"{{
  "pack_id": "{pack_id}",
  "name": "{name}",
  "version": "0.1.0",
  "author": "anonymous",
  "description": "Generated Malphas system template.",
  "entities": []
}}
"#
    );
    fs::write(dir.join("manifest.json"), manifest)?;

    println!("Initialized Malphas workspace at {}", dir.display());
    println!("  system crate: {}", systems_dir.display());
    println!("  manifest:     {}", dir.join("manifest.json").display());
    Ok(())
}

/// Builds a Rust `cdylib` crate and signs the resulting binary.
pub fn build_system(
    crate_dir: &Path,
    signing_key_env: Option<String>,
    signing_key_file: Option<PathBuf>,
) -> Result<(), Box<dyn Error>> {
    if !crate_dir.join("Cargo.toml").exists() {
        return Err(format!("{} does not contain a Cargo.toml", crate_dir.display()).into());
    }

    let status = Command::new("cargo")
        .args(["build", "--release"])
        .current_dir(crate_dir)
        .status()
        .map_err(|e| format!("failed to invoke cargo build: {e}"))?;
    if !status.success() {
        return Err("cargo build failed".into());
    }

    let target_dir = crate_dir.join("target").join("release");
    let binary_name = crate_dir.file_name().ok_or("invalid crate directory")?;
    let binary_name = binary_name.to_string_lossy().replace('-', "_");

    let candidates = [
        target_dir.join(format!("{binary_name}.dll")),
        target_dir.join(format!("lib{binary_name}.so")),
        target_dir.join(format!("lib{binary_name}.dylib")),
    ];
    let binary_path = candidates
        .iter()
        .find(|p| p.exists())
        .ok_or("no cdylib artifact found after build")?;

    let signing_key = signing_key_from_source(signing_key_env, signing_key_file)?;
    let data = fs::read(binary_path)?;
    let hash = Sha256::digest(&data);
    let signature = signing_key.sign(&hash);

    let sig_path = binary_path.with_extension(
        binary_path
            .extension()
            .and_then(|ext| ext.to_str())
            .map_or_else(|| "sig".to_string(), |ext| format!("{ext}.sig")),
    );
    fs::write(&sig_path, hex::encode(signature.to_bytes()))?;

    let public_hex = hex::encode(signing_key.verifying_key().to_bytes());
    println!("Built {}", binary_path.display());
    println!("Signature written to {}", sig_path.display());
    println!("Signer public key: {public_hex}");
    Ok(())
}

fn sanitize_id(name: &str) -> String {
    name.to_lowercase()
        .replace(|c: char| !c.is_alphanumeric() && c != '-' && c != '_', "-")
        .replace("--", "-")
        .trim_matches('-')
        .to_string()
}

fn seed_phrase_from_seed(seed: [u8; 32]) -> String {
    // Map each byte to one of 256 words.  This is a Malphas-local mnemonic,
    // not a BIP-39 wallet seed.
    seed.iter()
        .map(|b| DEFAULT_WORDLIST[*b as usize])
        .collect::<Vec<_>>()
        .join(" ")
}

//! Helper binary for signing Malphas native engine binaries with Ed25519.
//!
//! Usage:
//!   sign_engine generate
//!       Prints a fresh Ed25519 private/public key pair as hex strings.
//!
//!   sign_engine sign <engine_path> <private_key_hex>
//!       Signs the file at <engine_path> and writes <engine_path>.sig.

use ed25519_dalek::{Signer, SigningKey};
use rand_core::OsRng;
use std::env;
use std::process;

fn print_usage() {
    eprintln!("Usage:");
    eprintln!("  sign_engine generate");
    eprintln!("  sign_engine sign <engine_path> <private_key_hex>");
}

fn decode_hex_32(s: &str) -> Option<[u8; 32]> {
    let bytes = hex::decode(s.trim()).ok()?;
    if bytes.len() != 32 {
        return None;
    }
    let mut array = [0u8; 32];
    array.copy_from_slice(&bytes);
    Some(array)
}

fn generate() {
    let signing_key = SigningKey::generate(&mut OsRng);
    let verifying_key = signing_key.verifying_key();

    println!("private_key={}", hex::encode(signing_key.to_bytes()));
    println!("public_key={}", hex::encode(verifying_key.to_bytes()));
}

fn sign(engine_path: &str, private_key_hex: &str) -> Result<(), String> {
    let seed = decode_hex_32(private_key_hex)
        .ok_or_else(|| "Invalid private key: expected 64 hex characters".to_string())?;
    let signing_key = SigningKey::from_bytes(&seed);

    let data = std::fs::read(engine_path)
        .map_err(|e| format!("Failed to read engine binary '{}': {}", engine_path, e))?;

    let signature = signing_key.sign(&data);
    let sig_path = format!("{}.sig", engine_path);
    std::fs::write(&sig_path, hex::encode(signature.to_bytes()))
        .map_err(|e| format!("Failed to write signature '{}': {}", sig_path, e))?;

    println!("Signature written to {}", sig_path);
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().collect();

    match args.get(1).map(|s| s.as_str()) {
        Some("generate") => {
            if args.len() != 2 {
                print_usage();
                process::exit(1);
            }
            generate();
        }
        Some("sign") => {
            if args.len() != 4 {
                print_usage();
                process::exit(1);
            }
            if let Err(e) = sign(&args[2], &args[3]) {
                eprintln!("Error: {}", e);
                process::exit(1);
            }
        }
        _ => {
            print_usage();
            process::exit(1);
        }
    }
}

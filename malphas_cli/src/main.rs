//! Malphas package compiler and signer CLI (v3.0.0).
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
mod dev_tools;
mod environment;
mod manifest;
mod payload_schema;

use clap::{Parser, Subcommand};
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use sha2::{Digest, Sha256};
use std::error::Error;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use crate::bindings_codegen::generate_bindings_next_to_manifest;
use crate::compiler::compile_manifest;
use crate::dev_tools::{build_system, init_workspace, keygen, verify};
use crate::environment::{bundle_environment, list_bundle, unbundle_environment};
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
    /// Manage environment bundles (.menv).
    Environment {
        #[command(subcommand)]
        command: EnvironmentCommands,
    },
    /// Generate an Ed25519 signing keypair.
    Keygen {
        /// Output directory for the key files.
        #[arg(long, short, value_name = "DIR", default_value = ".")]
        output: PathBuf,
        /// Also write a local seed-phrase backup file.
        #[arg(long)]
        seed_phrase: bool,
    },
    /// Verify a sidecar signature against a public key.
    Verify {
        /// File whose signature should be checked.
        file: PathBuf,
        /// Public key hex string or path to a file containing it.
        #[arg(long, short, value_name = "KEY")]
        public_key: String,
    },
    /// Scaffold a new Malphas workspace with a package manifest and system crate.
    Init {
        /// Project name.
        name: String,
        /// Output directory.
        #[arg(long, short, value_name = "DIR", default_value = ".")]
        output: PathBuf,
    },
    /// Build a Rust `cdylib` system crate and sign the artifact.
    BuildSystem {
        /// Directory containing the system Cargo.toml.
        crate_dir: PathBuf,
        /// Read the 32-byte Ed25519 private key from this environment variable.
        #[arg(long, value_name = "VAR")]
        signing_key_env: Option<String>,
        /// Read the 32-byte Ed25519 private key from this file (use `-` for stdin).
        #[arg(long, value_name = "PATH")]
        signing_key_file: Option<PathBuf>,
    },
}

#[derive(Subcommand)]
enum EnvironmentCommands {
    /// Create a .menv bundle from an environment manifest.
    Bundle {
        /// Path to environment.json
        manifest: PathBuf,
        /// Workspace root that contains packages/ and systems/
        #[arg(long, value_name = "DIR")]
        workspace: PathBuf,
        /// Output .menv path
        #[arg(long, short, value_name = "PATH")]
        output: PathBuf,
    },
    /// Extract a .menv bundle into an installation directory.
    Unbundle {
        /// Path to .menv bundle
        bundle: PathBuf,
        /// Installation directory
        #[arg(long, short, value_name = "DIR")]
        output: PathBuf,
    },
    /// List the contents of a .menv bundle.
    List {
        /// Path to .menv bundle
        bundle: PathBuf,
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
        Commands::Environment { command } => {
            if let Err(e) = match command {
                EnvironmentCommands::Bundle {
                    manifest,
                    workspace,
                    output,
                } => bundle_environment(&manifest, &workspace, &output),
                EnvironmentCommands::Unbundle { bundle, output } => {
                    unbundle_environment(&bundle, &output).map(|_| ())
                }
                EnvironmentCommands::List { bundle } => list_bundle(&bundle),
            } {
                eprintln!("Environment command failed: {e}");
                std::process::exit(1);
            }
        }
        Commands::Keygen { output, seed_phrase } => {
            if let Err(e) = keygen(&output, seed_phrase) {
                eprintln!("Keygen failed: {e}");
                std::process::exit(1);
            }
        }
        Commands::Verify { file, public_key } => {
            if let Err(e) = verify(&file, &public_key) {
                eprintln!("Verify failed: {e}");
                std::process::exit(1);
            }
        }
        Commands::Init { name, output } => {
            if let Err(e) = init_workspace(&name, &output) {
                eprintln!("Init failed: {e}");
                std::process::exit(1);
            }
        }
        Commands::BuildSystem {
            crate_dir,
            signing_key_env,
            signing_key_file,
        } => {
            if let Err(e) = build_system(&crate_dir, signing_key_env, signing_key_file) {
                eprintln!("Build-system failed: {e}");
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

pub fn resolve_signing_key(
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

pub fn decode_hex_32(s: &str) -> Result<[u8; 32], Box<dyn Error>> {
    let cleaned = s.trim().trim_start_matches("0x").trim_start_matches("0X");
    let bytes = hex::decode(cleaned)?;
    if bytes.len() != 32 {
        return Err("Invalid private key: expected 64 hex characters".into());
    }
    let mut array = [0u8; 32];
    array.copy_from_slice(&bytes);
    Ok(array)
}

pub fn signing_key_from_source(
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

pub fn sign_file_with_key(file_path: &Path, signing_key: &SigningKey) -> Result<(), Box<dyn Error>> {
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

    #[test]
    fn environment_bundle_round_trip_preserves_manifest() {
        use crate::environment::{bundle_environment, unbundle_environment};

        let tmp_dir =
            std::env::temp_dir().join(format!("malphas_cli_env_test_{}", std::process::id()));
        fs::create_dir_all(&tmp_dir).unwrap();

        let manifest_path = tmp_dir.join("environment.json");
        let manifest_text = r#"{
            "id": "env_round_trip",
            "name": "Round Trip",
            "engineId": "demo_engine",
            "packageIds": ["demo_pack"]
        }"#;
        fs::write(&manifest_path, manifest_text).unwrap();

        let workspace = tmp_dir.join("workspace");
        let packages_dir = workspace.join("packages");
        fs::create_dir_all(&packages_dir).unwrap();
        fs::write(packages_dir.join("demo_pack.msp"), b"MSP").unwrap();
        fs::write(packages_dir.join("demo_pack.manifest.json"), b"{}")
            .unwrap();

        let bundle_path = tmp_dir.join("env_round_trip.menv");
        bundle_environment(&manifest_path, &workspace, &bundle_path).unwrap();
        assert!(bundle_path.exists());

        let install_dir = tmp_dir.join("install");
        let restored = unbundle_environment(&bundle_path, &install_dir).unwrap();
        assert_eq!(restored.id, "env_round_trip");
        assert_eq!(restored.name, "Round Trip");
        assert_eq!(restored.engine_id.as_deref(), Some("demo_engine"));
        assert_eq!(restored.package_ids, vec!["demo_pack"]);
        assert!(install_dir.join("packages").join("demo_pack.msp").exists());

        let _ = fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn keygen_creates_keypair_and_verify_passes() {
        use crate::dev_tools::{keygen, verify};

        let tmp_dir =
            std::env::temp_dir().join(format!("malphas_cli_keygen_test_{}", std::process::id()));
        fs::create_dir_all(&tmp_dir).unwrap();

        keygen(&tmp_dir, false).unwrap();
        assert!(tmp_dir.join("malphas_signing_key.hex").exists());
        assert!(tmp_dir.join("malphas_signing_key.pub").exists());

        let data_path = tmp_dir.join("payload.bin");
        fs::write(&data_path, b"keygen verify test").unwrap();

        let signing_key =
            signing_key_from_source(None, Some(tmp_dir.join("malphas_signing_key.hex"))).unwrap();
        sign_file_with_key(&data_path, &signing_key).unwrap();

        verify(&data_path, tmp_dir.join("malphas_signing_key.pub").to_str().unwrap()).unwrap();

        let _ = fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn init_creates_workspace_template() {
        use crate::dev_tools::init_workspace;

        let tmp_dir =
            std::env::temp_dir().join(format!("malphas_cli_init_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp_dir);

        init_workspace("Hello World", &tmp_dir).unwrap();
        assert!(tmp_dir.join("manifest.json").exists());
        assert!(tmp_dir.join("systems").join("hello-world").join("Cargo.toml").exists());
        assert!(tmp_dir
            .join("systems")
            .join("hello-world")
            .join("src")
            .join("lib.rs")
            .exists());

        let _ = fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn build_system_compiles_and_signs_template() {
        use crate::dev_tools::{build_system, init_workspace};

        let tmp_dir = std::env::temp_dir()
            .join(format!("malphas_cli_build_test_{}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp_dir);

        init_workspace("Build Test", &tmp_dir).unwrap();

        let key_dir = tmp_dir.join("keys");
        crate::dev_tools::keygen(&key_dir, false).unwrap();

        let crate_dir = tmp_dir.join("systems").join("build-test");
        build_system(
            &crate_dir,
            None,
            Some(key_dir.join("malphas_signing_key.hex")),
        )
        .unwrap();

        let artifact_candidates = [
            crate_dir.join("target").join("release").join("build_test.dll"),
            crate_dir.join("target").join("release").join("libbuild_test.so"),
            crate_dir.join("target").join("release").join("libbuild_test.dylib"),
        ];
        let artifact = artifact_candidates.iter().find(|p| p.exists()).unwrap();
        assert!(artifact.with_extension(
            artifact
                .extension()
                .and_then(|e| e.to_str())
                .map_or_else(|| "sig".to_string(), |e| format!("{e}.sig"))
        ).exists());

        let _ = fs::remove_dir_all(&tmp_dir);
    }
}

//! Environment bundle commands for `malphas-cli`.
//!
//! An environment bundle (`.menv`) is a ZIP archive that contains a JSON
//! manifest, the referenced `.msp` packages, and the optional system binaries
//! (`.mxc`/`.dll`/`.so`/`.dylib`) required to run the environment.

use serde::{Deserialize, Serialize};
use std::error::Error;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::Path;
use zip::write::SimpleFileOptions;
use zip::ZipArchive;

const ENVIRONMENT_MANIFEST: &str = "environment.json";
const PACKAGES_DIR: &str = "packages";
const SYSTEMS_DIR: &str = "systems";

#[derive(Debug, Serialize, Deserialize)]
pub struct EnvironmentManifest {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default, rename = "engineId")]
    pub engine_id: Option<String>,
    #[serde(default, rename = "packageIds")]
    pub package_ids: Vec<String>,
    #[serde(default)]
    pub policy: EnvironmentPolicy,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct EnvironmentPolicy {
    #[serde(default)]
    pub read_only: bool,
    #[serde(default, rename = "allowFilesystemAccess")]
    pub allow_filesystem_access: bool,
    #[serde(default)]
    pub allow_network: bool,
    #[serde(default)]
    pub allow_audio: bool,
    #[serde(default, rename = "allowLocationTelemetry")]
    pub allow_location_telemetry: bool,
    #[serde(default, rename = "maxRamBytes")]
    pub max_ram_bytes: u64,
}

/// Package an environment manifest and its referenced artifacts into a `.menv` bundle.
pub fn bundle_environment(
    manifest_path: &Path,
    workspace_root: &Path,
    output_path: &Path,
) -> Result<(), Box<dyn Error>> {
    let manifest_text = fs::read_to_string(manifest_path)?;
    let env_manifest: EnvironmentManifest = serde_json::from_str(&manifest_text)?;

    let options = SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .compression_level(Some(6));

    let output_file = File::create(output_path)?;
    let mut zip = zip::ZipWriter::new(output_file);

    zip.start_file_from_path(ENVIRONMENT_MANIFEST, options)?;
    zip.write_all(manifest_text.as_bytes())?;

    let packages_dir = workspace_root.join("packages");
    let systems_dir = workspace_root.join("systems");

    for package_id in &env_manifest.package_ids {
        let msp_src = packages_dir.join(format!("{package_id}.msp"));
        let manifest_src = packages_dir.join(format!("{package_id}.manifest.json"));

        if msp_src.exists() {
            let entry_name = Path::new(PACKAGES_DIR).join(format!("{package_id}.msp"));
            zip.start_file_from_path(&entry_name, options)?;
            let mut file = File::open(&msp_src)?;
            let mut buffer = Vec::new();
            file.read_to_end(&mut buffer)?;
            zip.write_all(&buffer)?;
        }

        if manifest_src.exists() {
            let entry_name =
                Path::new(PACKAGES_DIR).join(format!("{package_id}.manifest.json"));
            zip.start_file_from_path(&entry_name, options)?;
            let mut file = File::open(&manifest_src)?;
            let mut buffer = Vec::new();
            file.read_to_end(&mut buffer)?;
            zip.write_all(&buffer)?;
        }
    }

    if let Some(engine_id) = &env_manifest.engine_id {
        for ext in ["mxc", "dll", "so", "dylib"] {
            let candidate = systems_dir.join(format!("{engine_id}.{ext}"));
            if candidate.exists() {
                let entry_name = Path::new(SYSTEMS_DIR).join(candidate.file_name().unwrap());
                zip.start_file_from_path(&entry_name, options)?;
                let mut file = File::open(&candidate)?;
                let mut buffer = Vec::new();
                file.read_to_end(&mut buffer)?;
                zip.write_all(&buffer)?;
            }
        }
    }

    zip.finish()?;
    println!(
        "Bundled environment '{}' into {}",
        env_manifest.name,
        output_path.display()
    );
    Ok(())
}

/// Extract a `.menv` bundle into an installation directory.
pub fn unbundle_environment(
    bundle_path: &Path,
    install_dir: &Path,
) -> Result<EnvironmentManifest, Box<dyn Error>> {
    let file = File::open(bundle_path)?;
    let mut archive = ZipArchive::new(file)?;

    if !install_dir.exists() {
        fs::create_dir_all(install_dir)?;
    }

    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let entry_path = entry
            .enclosed_name()
            .ok_or("bundle entry escapes the archive root")?;

        let target = install_dir.join(entry_path);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }

        let mut output = File::create(&target)?;
        let mut buffer = Vec::new();
        entry.read_to_end(&mut buffer)?;
        output.write_all(&buffer)?;
    }

    let manifest_path = install_dir.join(ENVIRONMENT_MANIFEST);
    let manifest_text = fs::read_to_string(&manifest_path)?;
    let env_manifest: EnvironmentManifest = serde_json::from_str(&manifest_text)?;

    println!(
        "Installed environment '{}' to {}",
        env_manifest.name,
        install_dir.display()
    );
    Ok(env_manifest)
}

/// List the contents of a `.menv` bundle without extracting it.
pub fn list_bundle(bundle_path: &Path) -> Result<(), Box<dyn Error>> {
    let file = File::open(bundle_path)?;
    let mut archive = ZipArchive::new(file)?;

    let mut manifest: Option<EnvironmentManifest> = None;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        if entry.name() == ENVIRONMENT_MANIFEST {
            let mut text = String::new();
            entry.read_to_string(&mut text)?;
            manifest = Some(serde_json::from_str(&text)?);
        }
    }

    if let Some(m) = manifest {
        println!("Environment: {} (id={})", m.name, m.id);
        println!("  engine_id:   {:?}", m.engine_id);
        println!("  packages:    {:?}", m.package_ids);
        println!("  read_only:   {}", m.policy.read_only);
        println!("  max_ram:     {} bytes", m.policy.max_ram_bytes);
    } else {
        println!("Warning: bundle does not contain {ENVIRONMENT_MANIFEST}");
    }

    println!("\nArchive contents:");
    for i in 0..archive.len() {
        let entry = archive.by_index(i)?;
        println!("  {} ({} bytes)", entry.name(), entry.size());
    }

    Ok(())
}

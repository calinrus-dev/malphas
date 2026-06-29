# build_core.ps1 — Windows native core build script for Malphas.
# Mirrors the Windows desktop behavior of build.sh.
#
# NOTE: Android cross-compilation is not supported by this script. Android
# libraries (arm64-v8a, armeabi-v7a, x86_64) must be built on Linux/macOS
# via ./build.sh when ANDROID_NDK_HOME is set, or obtained from CI artifacts.
#
# Usage (from repo root):
#   .\build_core.ps1

# Resolve repository root (directory containing this script, or current location)
$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Color helpers
function Write-Info    { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Ok      { param([string]$Message) Write-Host "[OK]   $Message" -ForegroundColor Green }
function Write-Warn    { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-ErrorEx { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

# Windows-specific library name and extension
$libName = 'malphas_core.dll'
$ext     = 'dll'

# Workspace-wide build artifacts live in target/release at the repo root
$srcLib = Join-Path (Join-Path $root 'target/release') $libName
$sigSrc = "$srcLib.sig"
$rootSig = Join-Path $root "$libName.sig"

$motorsDir = Join-Path $root 'flutter_app/motors'
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$stampedName = "malphas_core_${timestamp}.${ext}"
$stampedPath = Join-Path $motorsDir $stampedName

# Build the Rust core and CLI from the workspace root in release mode
Write-Info "Building Rust workspace in release mode..."
Push-Location $root
try {
    cargo build --release --package malphas_core
    if ($LASTEXITCODE -ne 0) { throw "cargo build malphas_core failed with exit code $LASTEXITCODE" }

    cargo build --release --package malphas_cli
    if ($LASTEXITCODE -ne 0) { throw "cargo build malphas_cli failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}

# Verify the compiled DLL exists
if (-not (Test-Path $srcLib -PathType Leaf)) {
    Write-ErrorEx "Compiled library not found: $srcLib"
    exit 1
}
Write-Ok "Built core: $srcLib"

# Verify the compiled CLI executable
$cliName = 'malphas-cli.exe'
$cliSrc = Join-Path (Join-Path $root 'target/release') $cliName
if (-not (Test-Path $cliSrc -PathType Leaf)) {
    Write-Warn "Compiled CLI executable not found: $cliSrc"
} else {
    Write-Ok "Built CLI: $cliSrc"
}

# Determine signature source (next to DLL, with fallback to repo root)
if (Test-Path $sigSrc -PathType Leaf) {
    Write-Ok "Found signature next to library: $sigSrc"
} elseif (Test-Path $rootSig -PathType Leaf) {
    $sigSrc = $rootSig
    Write-Ok "Found signature at repo root: $sigSrc"
} else {
    $sigSrc = $null
    Write-Warn "No signature file found for $libName"
}

# Ensure the motors directory exists
New-Item -ItemType Directory -Force -Path $motorsDir | Out-Null

# Copy the built library to flutter_app/motors with a timestamped name
Write-Info "Copying $libName to motors/ as $stampedName..."
Copy-Item -Path $srcLib -Destination $stampedPath -Force
Write-Ok "Copied motor: $stampedPath"

if ($sigSrc) {
    Copy-Item -Path $sigSrc -Destination "$stampedPath.sig" -Force
    Write-Ok "Copied signature: $stampedPath.sig"
}

# Copy the CLI executable into flutter_app/motors so Dart can invoke it
if (Test-Path $cliSrc -PathType Leaf) {
    Write-Info "Copying CLI executable to motors/..."
    Copy-Item -Path $cliSrc -Destination $motorsDir -Force
    Write-Ok "Copied CLI: $(Join-Path $motorsDir $cliName)"
}

# Copy a non-timestamped copy of the library and signature to the workspace root
Write-Info "Copying non-timestamped motor to workspace root..."
$rootLib = Join-Path $root $libName
Copy-Item -Path $srcLib -Destination $rootLib -Force
Write-Ok "Copied motor: $rootLib"
if ($sigSrc) {
    Copy-Item -Path $sigSrc -Destination "$rootLib.sig" -Force
    Write-Ok "Copied signature: $rootLib.sig"
}

# Clean up old timestamped motors, keeping only the 3 most recent for this variant
Write-Info "Cleaning up old $ext motors (keeping the 3 most recent)..."
$oldMotors = Get-ChildItem -Path $motorsDir -Filter "malphas_core_*.$ext" -File |
    Sort-Object LastWriteTime -Descending

if ($oldMotors.Count -gt 3) {
    $oldMotors | Select-Object -Skip 3 | ForEach-Object {
        $old = $_.FullName
        Write-Info "Removing old motor: $old"
        Remove-Item -Path $old -Force -ErrorAction SilentlyContinue
        # Also remove its companion signature if present
        Remove-Item -Path "$old.sig" -Force -ErrorAction SilentlyContinue
    }
}
Write-Ok "Motor cleanup complete"

# Copy the latest library + signature into existing Flutter build directories
Write-Info "Copying latest library into existing Flutter build directories..."
$flutterTargets = @(
    Join-Path $root 'flutter_app/build/windows/x64/runner/Debug'
    Join-Path $root 'flutter_app/build/windows/x64/runner/Release'
)

foreach ($target in $flutterTargets) {
    if (Test-Path $target -PathType Container) {
        $targetLib = Join-Path $target $libName
        Copy-Item -Path $srcLib -Destination $targetLib -Force
        Write-Ok "Copied library to: $targetLib"
        if ($sigSrc) {
            Copy-Item -Path $sigSrc -Destination "$targetLib.sig" -Force
            Write-Ok "Copied signature to: $targetLib.sig"
        }
    }
}

# Warn if the user expects Android cross-compilation from Windows.
if ($env:ANDROID_NDK_HOME -or $env:ANDROID_NDK_ROOT) {
    Write-Warn "ANDROID_NDK_HOME is set but this script does not cross-compile Android libraries. Use ./build.sh on Linux/macOS or CI artifacts instead."
}

Write-Ok "Build complete."

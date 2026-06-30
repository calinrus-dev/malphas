#!/usr/bin/env bash
# build.sh — Cross-platform native core build script for Malphas.
# Replicates and extends build_core.ps1 for Linux, macOS, and Windows (Git Bash).
#
# Usage (from repo root):
#   ./build.sh

set -euo pipefail

# Resolve repository root (directory containing this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"

# Color helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Detect platform and choose the dynamic library name
info "Detecting platform..."
case "$(uname -s)" in
    Linux*)     PLATFORM="linux";   LIB_NAME="libmalphas_core.so";    EXT="so" ;;
    Darwin*)    PLATFORM="macos";   LIB_NAME="libmalphas_core.dylib"; EXT="dylib" ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
                PLATFORM="windows"; LIB_NAME="malphas_core.dll";      EXT="dll" ;;
    *)
                error "Unsupported platform: $(uname -s)"
                exit 1
                ;;
esac
ok "Platform: $PLATFORM ($LIB_NAME)"

# Workspace-wide build artifacts live in target/release at the repo root
SRC_LIB="$ROOT/target/release/$LIB_NAME"
SIG_SRC="$SRC_LIB.sig"
# Fallback to a signature located at the repo root (e.g. malphas_core.dll.sig)
ROOT_SIG="$ROOT/$LIB_NAME.sig"

MOTORS_DIR="$ROOT/flutter_app/motors"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
STAMPED_NAME="malphas_core_${TIMESTAMP}.${EXT}"
STAMPED_PATH="$MOTORS_DIR/$STAMPED_NAME"

# Build the Rust core, CLI, and example system from the workspace root in release mode
info "Building Rust workspace in release mode..."
(
    cd "$ROOT"
    cargo build --release --package malphas_core
    cargo build --release --package malphas_cli
    cargo build --release --package bouncing_demo
)

if [ ! -f "$SRC_LIB" ]; then
    error "Compiled library not found: $SRC_LIB"
    exit 1
fi
ok "Built core: $SRC_LIB"

# Determine CLI executable name (malphas-cli on Unix, malphas-cli.exe on Windows)
CLI_NAME="malphas-cli"
CLI_SRC="$ROOT/target/release/$CLI_NAME"
if [ "$PLATFORM" = "windows" ]; then
    CLI_SRC="$ROOT/target/release/${CLI_NAME}.exe"
fi
if [ ! -f "$CLI_SRC" ]; then
    warn "Compiled CLI executable not found: $CLI_SRC"
else
    ok "Built CLI: $CLI_SRC"
fi

# Determine signature source
if [ -f "$SIG_SRC" ]; then
    ok "Found signature next to library: $SIG_SRC"
elif [ -f "$ROOT_SIG" ]; then
    SIG_SRC="$ROOT_SIG"
    ok "Found signature at repo root: $SIG_SRC"
else
    SIG_SRC=""
    warn "No signature file found for $LIB_NAME"
fi

# Ensure the motors directory exists
mkdir -p "$MOTORS_DIR"

# Copy the built library to flutter_app/motors with a timestamped name
info "Copying $LIB_NAME to motors/ as $STAMPED_NAME..."
cp -f "$SRC_LIB" "$STAMPED_PATH"
ok "Copied motor: $STAMPED_PATH"

# Copy signature alongside the timestamped motor if available
if [ -n "$SIG_SRC" ]; then
    cp -f "$SIG_SRC" "$STAMPED_PATH.sig"
    ok "Copied signature: $STAMPED_PATH.sig"
fi

# Copy the CLI executable into flutter_app/motors so Dart can invoke it
if [ -f "$CLI_SRC" ]; then
    info "Copying CLI executable to motors/..."
    cp -f "$CLI_SRC" "$MOTORS_DIR/"
    ok "Copied CLI: $MOTORS_DIR/$(basename "$CLI_SRC")"
fi

# Copy the example bouncing_demo system (.mxc) into motors/ and the workspace root
case "$PLATFORM" in
    windows) SYS_NAME="bouncing_demo.dll" ;;
    linux)   SYS_NAME="libbouncing_demo.so" ;;
    macos)   SYS_NAME="libbouncing_demo.dylib" ;;
esac
SYS_SRC="$ROOT/target/release/$SYS_NAME"
if [ -f "$SYS_SRC" ]; then
    info "Copying bouncing_demo system to motors/..."
    cp -f "$SYS_SRC" "$MOTORS_DIR/$SYS_NAME"
    ok "Copied system: $MOTORS_DIR/$SYS_NAME"
    cp -f "$SYS_SRC" "$ROOT/$SYS_NAME"
    ok "Copied system: $ROOT/$SYS_NAME"

    # Also copy as .mxc so the workspace loader can treat it as a system file.
    cp -f "$SYS_SRC" "$ROOT/examples/bouncing_demo/bouncing_demo.mxc" || true
    cp -f "$SYS_SRC" "$MOTORS_DIR/bouncing_demo.mxc" || true
    ok "Copied system .mxc: $ROOT/examples/bouncing_demo/bouncing_demo.mxc"
fi

# Copy a non-timestamped copy of the library and signature to the workspace root
# so tests can locate them without relying on the PowerShell build script.
info "Copying non-timestamped motor to workspace root..."
cp -f "$SRC_LIB" "$ROOT/$LIB_NAME"
ok "Copied motor: $ROOT/$LIB_NAME"
if [ -n "$SIG_SRC" ] && [ "$SIG_SRC" != "$ROOT/$LIB_NAME.sig" ]; then
    cp -f "$SIG_SRC" "$ROOT/$LIB_NAME.sig"
    ok "Copied signature: $ROOT/$LIB_NAME.sig"
fi

# Clean up old timestamped motors, keeping only the most recent 3 for this variant
info "Cleaning up old $EXT motors (keeping the 3 most recent)..."
shopt -s nullglob
old_motors=("$MOTORS_DIR"/malphas_core_*.$EXT)
if [ ${#old_motors[@]} -gt 3 ]; then
    printf '%s\n' "${old_motors[@]}" | sort -r | tail -n +4 | while IFS= read -r old; do
        info "Removing old motor: $old"
        rm -f "$old"
        # Also remove its companion signature if present
        rm -f "$old.sig"
    done
fi
shopt -u nullglob
ok "Motor cleanup complete"

# Copy the latest library + signature into existing Flutter build directories
info "Copying latest library into existing Flutter build directories..."

case "$PLATFORM" in
    windows)
        flutter_targets=(
            "$ROOT/flutter_app/build/windows/x64/runner/Debug"
            "$ROOT/flutter_app/build/windows/x64/runner/Release"
        )
        ;;
    linux)
        flutter_targets=(
            "$ROOT/flutter_app/build/linux/x64/debug/bundle/lib"
            "$ROOT/flutter_app/build/linux/x64/release/bundle/lib"
        )
        ;;
    macos)
        flutter_targets=(
            "$ROOT/flutter_app/build/macos/Build/Products/Debug"
            "$ROOT/flutter_app/build/macos/Build/Products/Release"
            "$ROOT/flutter_app/build/macos/Build/Products/Debug/Malphas.app/Contents/Frameworks"
            "$ROOT/flutter_app/build/macos/Build/Products/Release/Malphas.app/Contents/Frameworks"
        )
        ;;
esac

for target in "${flutter_targets[@]}"; do
    if [ -d "$target" ]; then
        cp -f "$SRC_LIB" "$target/$LIB_NAME"
        ok "Copied library to: $target/$LIB_NAME"
        if [ -n "$SIG_SRC" ]; then
            cp -f "$SIG_SRC" "$target/$LIB_NAME.sig"
            ok "Copied signature to: $target/$LIB_NAME.sig"
        fi
    fi
done

# -----------------------------------------------------------------------------

# Optional Android cross-compilation when the NDK is available.
# -----------------------------------------------------------------------------
build_android() {
    local ndk=""
    if [ -n "${ANDROID_NDK_HOME:-}" ]; then
        ndk="$ANDROID_NDK_HOME"
    elif [ -n "${ANDROID_NDK_ROOT:-}" ]; then
        ndk="$ANDROID_NDK_ROOT"
    fi
    [ -n "$ndk" ] || return 0

    # Pick the NDK prebuilt host tag that matches this machine.
    # NDK r26c ships linux-x86_64, darwin-x86_64 (runs on Apple Silicon via Rosetta),
    # and windows-x86_64 toolchains.
    local host_tag
    case "$(uname -s)" in
        Linux*)     host_tag="linux-x86_64" ;;
        Darwin*)    host_tag="darwin-x86_64" ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT)
                    host_tag="windows-x86_64" ;;
        *)          host_tag="linux-x86_64" ;;
    esac

    local toolchain="$ndk/toolchains/llvm/prebuilt/$host_tag/bin"
    if [ ! -d "$toolchain" ]; then
        warn "Android NDK toolchain not found at $toolchain; skipping Android build."
        return 0
    fi

    info "Android NDK detected; building multi-arch libraries..."
    local abis=(
        "arm64-v8a:aarch64-linux-android"
        "armeabi-v7a:armv7-linux-androideabi"
        "x86_64:x86_64-linux-android"
    )

    # Remove any previously-deployed Android libraries so we never bundle a
    # host-arch artifact inside an ABI directory (e.g. x86_64 desktop .so in
    # arm64-v8a).
    for entry in "${abis[@]}"; do
        local abi="${entry%%:*}"
        rm -rf "$ROOT/flutter_app/android/app/src/main/jniLibs/$abi"
    done

    for entry in "${abis[@]}"; do
        local abi="${entry%%:*}"
        local target="${entry#*:}"
        info "Building $abi ($target)..."
        if ! cargo build --release --target "$target" --package malphas_core; then
            error "Failed to build $target; aborting Android build."
            exit 1
        fi
        local out="$ROOT/flutter_app/android/app/src/main/jniLibs/$abi"
        mkdir -p "$out"
        cp -f "$ROOT/target/$target/release/libmalphas_core.so" "$out/libmalphas_core.so"
        ok "Copied Android library to: $out/libmalphas_core.so"
    done
}

build_android

ok "Build complete."

#!/usr/bin/env bash
# sync_version.sh — Propagate the root VERSION file to all versioned files.
#
# Updates:
#   * Cargo.toml workspace version
#   * flutter_app/pubspec.yaml version prefix
#   * README.md title
#   * malphas_core/src/pipeline.rs BRIDGE_ABI_VERSION

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"

if [ ! -f "$VERSION_FILE" ]; then
    echo "ERROR: VERSION file not found at $VERSION_FILE"
    exit 1
fi

VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
if ! echo "$VERSION" | grep -qxE '[0-9]+\.[0-9]+\.[0-9]+'; then
    echo "ERROR: VERSION ($VERSION) is not a valid semver string."
    exit 1
fi

MAJOR=$(echo "$VERSION" | cut -d. -f1)
MINOR=$(echo "$VERSION" | cut -d. -f2)
PATCH=$(echo "$VERSION" | cut -d. -f3)
# Encode each semver component as two BCD digits (e.g. 2.10.0 -> 0x02100000).
major_bcd=$(( MAJOR / 10 * 16 + MAJOR % 10 ))
minor_bcd=$(( MINOR / 10 * 16 + MINOR % 10 ))
patch_bcd=$(( PATCH / 10 * 16 + PATCH % 10 ))
ABI_VERSION=$(printf '0x%02x%02x%02x00' "$major_bcd" "$minor_bcd" "$patch_bcd")

echo "Syncing version $VERSION (ABI $ABI_VERSION) ..."

# Cargo.toml workspace version
sed -i -E "s/^version = \"[0-9]+\.[0-9]+\.[0-9]+\"/version = \"$VERSION\"/" "$ROOT/Cargo.toml"

# flutter_app/pubspec.yaml version prefix (preserve +N build number)
sed -i -E "s/^version: [0-9]+\.[0-9]+\.[0-9]+/version: $VERSION/" "$ROOT/flutter_app/pubspec.yaml"

# README.md title
sed -i -E "s/^# Malphas( Engine)? v[0-9]+\.[0-9]+\.[0-9]+/# Malphas Engine v$VERSION/" "$ROOT/README.md"

# BRIDGE_ABI_VERSION in Rust core
sed -i -E "s/pub const BRIDGE_ABI_VERSION: u32 = 0x[0-9a-fA-F]+;/pub const BRIDGE_ABI_VERSION: u32 = $ABI_VERSION;/" "$ROOT/malphas_core/src/pipeline.rs"

echo "Version sync complete. Run scripts/check_version_sync.sh to verify."

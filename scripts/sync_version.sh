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
ABI_VERSION=$(printf '0x%02x%02x%02x00' "$MAJOR" "$MINOR" "$PATCH")

echo "Syncing version $VERSION (ABI $ABI_VERSION) ..."

# Cargo.toml workspace version
sed -i -E "s/^version = \"[0-9]+\.[0-9]+\.[0-9]+\"/version = \"$VERSION\"/" "$ROOT/Cargo.toml"

# flutter_app/pubspec.yaml version prefix (preserve +N build number)
sed -i -E "s/^version: [0-9]+\.[0-9]+\.[0-9]+/version: $VERSION/" "$ROOT/flutter_app/pubspec.yaml"

# README.md title
sed -i -E "s/^# Malphas v[0-9]+\.[0-9]+\.[0-9]+/# Malphas v$VERSION/" "$ROOT/README.md"

# BRIDGE_ABI_VERSION in Rust core
sed -i -E "s/pub const BRIDGE_ABI_VERSION: u32 = 0x[0-9a-fA-F]+;/pub const BRIDGE_ABI_VERSION: u32 = $ABI_VERSION;/" "$ROOT/malphas_core/src/pipeline.rs"

echo "Version sync complete. Run scripts/check_version_sync.sh to verify."

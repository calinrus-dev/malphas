#!/usr/bin/env bash
# check_version_sync.sh — Ensure all version strings derive from the root VERSION file.
#
# Verifies:
#   * VERSION file exists and is semver.
#   * Cargo.toml workspace version matches VERSION.
#   * flutter_app/pubspec.yaml version prefix matches VERSION.
#   * README.md title contains Malphas vVERSION.
#   * malphas_core/src/pipeline.rs BRIDGE_ABI_VERSION matches VERSION.
#   * No crate overrides the workspace version.

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
EXPECTED_ABI_VERSION=$(printf '0x%02x%02x%02x00' "$major_bcd" "$minor_bcd" "$patch_bcd")

cargo_version=$(grep -E '^version[[:space:]]*=' "$ROOT/Cargo.toml" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
flutter_version=$(grep -E '^version:' "$ROOT/flutter_app/pubspec.yaml" | head -n1 | sed -E 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
readme_version=$(grep -E '^# Malphas( Engine)? v[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/README.md" | head -n1 | sed -E 's/.*v([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
abi_version=$(grep -E 'pub const BRIDGE_ABI_VERSION:' "$ROOT/malphas_core/src/pipeline.rs" | sed -E 's/.*=[[:space:]]*(0x[0-9a-fA-F]+).*/\1/')

echo "VERSION file:      $VERSION"
echo "Cargo.toml:        $cargo_version"
echo "pubspec.yaml:      $flutter_version"
echo "README.md:         $readme_version"
echo "BRIDGE_ABI_VERSION: $abi_version (expected $EXPECTED_ABI_VERSION)"

ERRORS=0

if [ "$cargo_version" != "$VERSION" ]; then
    echo "ERROR: Cargo workspace version ($cargo_version) does not match VERSION ($VERSION)."
    ERRORS=$((ERRORS + 1))
fi

if [ "$flutter_version" != "$VERSION" ]; then
    echo "ERROR: Flutter version ($flutter_version) does not match VERSION ($VERSION)."
    ERRORS=$((ERRORS + 1))
fi

if [ "$readme_version" != "$VERSION" ]; then
    echo "ERROR: README.md version ($readme_version) does not match VERSION ($VERSION)."
    ERRORS=$((ERRORS + 1))
fi

if [ "$abi_version" != "$EXPECTED_ABI_VERSION" ]; then
    echo "ERROR: BRIDGE_ABI_VERSION ($abi_version) does not match expected $EXPECTED_ABI_VERSION."
    ERRORS=$((ERRORS + 1))
fi

overrides=$(grep -R -n --include='Cargo.toml' '^version[[:space:]]*=[[:space:]]*"' "$ROOT"/*/Cargo.toml "$ROOT"/systems/*/Cargo.toml 2>/dev/null || true)
if [ -n "$overrides" ]; then
    echo "ERROR: Some crates override the workspace version instead of using version.workspace = true:"
    echo "$overrides"
    ERRORS=$((ERRORS + 1))
fi

if [ "$ERRORS" -gt 0 ]; then
    echo "Version sync FAILED with $ERRORS error(s). Run scripts/sync_version.sh to fix."
    exit 1
fi

echo "Version sync OK."

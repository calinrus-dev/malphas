#!/usr/bin/env bash
# check_version_sync.sh — Ensure workspace version strings stay in sync.
#
# Verifies:
#   * Cargo.toml workspace version matches flutter_app/pubspec.yaml version prefix.
#   * No crate overrides the workspace version.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cargo_version=$(grep -E '^version\s*=' "$ROOT/Cargo.toml" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
flutter_version=$(grep -E '^version:' "$ROOT/flutter_app/pubspec.yaml" | head -n1 | sed -E 's/.*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')

echo "Cargo workspace version: $cargo_version"
echo "Flutter pubspec version: $flutter_version"

if [ "$cargo_version" != "$flutter_version" ]; then
    echo "ERROR: Cargo workspace version ($cargo_version) does not match Flutter version ($flutter_version)."
    exit 1
fi

overrides=$(grep -R -n --include='Cargo.toml' '^version\s*=\s*"' "$ROOT"/*/Cargo.toml "$ROOT"/systems/*/Cargo.toml 2>/dev/null || true)
if [ -n "$overrides" ]; then
    echo "ERROR: Some crates override the workspace version instead of using version.workspace = true:"
    echo "$overrides"
    exit 1
fi

echo "Version sync OK."

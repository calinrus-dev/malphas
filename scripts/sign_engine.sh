#!/usr/bin/env bash
# sign_engine.sh
# Signs a Malphas native engine binary with an Ed25519 private key.
#
# Usage:
#   ./sign_engine.sh <engine_path> <private_key_hex>
#
# The signature is written next to the binary as <engine_path>.sig.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <engine_path> <private_key_hex>"
    exit 1
fi

ENGINE_PATH="$1"
PRIVATE_KEY_HEX="$2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ENGINE_PATH="$(realpath "$ENGINE_PATH")"

echo "Signing engine binary: $ENGINE_PATH"

cargo run --release --manifest-path "$ROOT/malphas_core/Cargo.toml" --bin sign_engine -- sign "$ENGINE_PATH" "$PRIVATE_KEY_HEX"

echo "Signing complete."

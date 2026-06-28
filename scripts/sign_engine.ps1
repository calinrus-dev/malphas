# sign_engine.ps1
# Signs a Malphas native engine binary with an Ed25519 private key.
#
# Usage:
#   .\sign_engine.ps1 -EnginePath <path> -PrivateKeyHex <hex>
#
# The signature is written next to the binary as <engine_path>.sig.

param(
    [Parameter(Mandatory = $true)]
    [string]$EnginePath,

    [Parameter(Mandatory = $true)]
    [string]$PrivateKeyHex
)

$root = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { Get-Location }

$EnginePath = Resolve-Path $EnginePath -ErrorAction Stop | Select-Object -ExpandProperty Path

Write-Host "Signing engine binary: $EnginePath" -ForegroundColor Green

cargo run --release --manifest-path "$root/malphas_core/Cargo.toml" --bin sign_engine -- sign "$EnginePath" "$PrivateKeyHex"
if ($LASTEXITCODE -ne 0) {
    throw "Signing failed with exit code $LASTEXITCODE"
}

Write-Host "Signing complete." -ForegroundColor Cyan

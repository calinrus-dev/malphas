# build_core.ps1
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }

Write-Host "Compilando Rust Core en modo Release..." -ForegroundColor Green
Push-Location "$root"
cargo build --release --package malphas_core
Pop-Location

$dllSource = "$root/target/release/malphas_core.dll"
if (Test-Path $dllSource) {
    Write-Host "Copiando DLL a la raíz y a carpetas de Flutter..." -ForegroundColor Green
    Copy-Item $dllSource "$root/malphas_core.dll" -Force
    Copy-Item $dllSource "$root/flutter_app/malphas_core.dll" -Force

    # Copiar la firma Ed25519 junto al binario si existe
    $sigSource = "$root/malphas_core.dll.sig"
    if (Test-Path $sigSource) {
        Copy-Item $sigSource "$root/flutter_app/malphas_core.dll.sig" -Force
    }

    # Intentar copiar a carpetas de compilación de Windows de Flutter si existen
    $debugPath = "$root/flutter_app/build/windows/x64/runner/Debug"
    if (Test-Path $debugPath) {
        Copy-Item $dllSource "$debugPath/malphas_core.dll" -Force
        if (Test-Path $sigSource) {
            Copy-Item $sigSource "$debugPath/malphas_core.dll.sig" -Force
        }
        Write-Host "Copiando DLL a $debugPath" -ForegroundColor Green
    }

    $releasePath = "$root/flutter_app/build/windows/x64/runner/Release"
    if (Test-Path $releasePath) {
        Copy-Item $dllSource "$releasePath/malphas_core.dll" -Force
        if (Test-Path $sigSource) {
            Copy-Item $sigSource "$releasePath/malphas_core.dll.sig" -Force
        }
        Write-Host "Copiando DLL a $releasePath" -ForegroundColor Green
    }

    Write-Host "Proceso completado con éxito." -ForegroundColor Cyan
} else {
    Write-Error "No se pudo encontrar el DLL compilado en $dllSource"
}

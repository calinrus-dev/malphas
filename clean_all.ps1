# Detener motores colgados que bloquean el heap y los archivos del sistema
Stop-Process -Name "dart" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "flutter" -Force -ErrorAction SilentlyContinue

# Limpieza quirúrgica de binarios temporales y cachés
Write-Output "🧹 Ejecutando purga radical..."
Get-ChildItem -Path . -Filter "malphas_core_temp_*" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
Get-ChildItem -Path . -Filter "*.pdb" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue

# Reset de entornos de construcción
cargo clean
if (Test-Path "flutter_app") {
    Push-Location "flutter_app"
    flutter clean
    Pop-Location
}
Write-Output "✨ Entorno limpio."

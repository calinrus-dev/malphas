Param()

# Remove compiled artifacts and temporary files that should not be committed
Write-Host "Cleaning build artifacts..."
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\malphas_core\target
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\flutter_app\build
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\flutter_app\.dart_tool
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\flutter_app\.flutter-plugins
Write-Host "Done. Review .gitignore before committing changes."

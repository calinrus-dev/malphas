Param()

# Remove compiled artifacts and temporary files that should not be committed
Write-Host "Cleaning build artifacts..."
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\target
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\flutter_app\build
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\flutter_app\.dart_tool
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\flutter_app\.flutter-plugins
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\flutter_app\motors\*
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue .\malphas_state
Remove-Item -Force -ErrorAction SilentlyContinue .\malphas_core.dll
Remove-Item -Force -ErrorAction SilentlyContinue .\malphas_core.dll.sig
Remove-Item -Force -ErrorAction SilentlyContinue .\libmalphas_core.so
Remove-Item -Force -ErrorAction SilentlyContinue .\libmalphas_core.so.sig
Remove-Item -Force -ErrorAction SilentlyContinue .\libmalphas_core.dylib
Remove-Item -Force -ErrorAction SilentlyContinue .\libmalphas_core.dylib.sig
Write-Host "Done. Review .gitignore before committing changes."

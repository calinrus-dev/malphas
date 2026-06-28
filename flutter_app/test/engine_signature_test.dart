import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:malphas_app/core/ffi/malphas_bindings.dart';
import 'package:malphas_app/features/engine_manager/engine_controller.dart';
import 'package:malphas_app/features/engine_manager/models.dart';

void main() {
  test(
      'Engine verification marks local DLL standby with .sig and corrupt without',
      () {
    final bindings = MalphasBindings();
    if (!bindings.isNativeAvailable) {
      // Skip when the native library cannot be loaded (headless CI).
      return;
    }

    final controller = EngineController();
    // The test may run from flutter_app/ or from the repo root.
    var workspace = Directory.current.path;
    final binaryName =
        Platform.isWindows ? 'malphas_core.dll' : 'libmalphas_core.so';
    if (!File('$workspace/$binaryName').existsSync()) {
      workspace = Directory.current.parent.path;
    }
    final dllPath = '$workspace/$binaryName';
    final sigPath = '$dllPath.sig';
    final sigBackupPath = '$dllPath.sig.bak';
    final sigFile = File(sigPath);

    // Ensure the binary and a valid signature exist.
    if (!File(dllPath).existsSync()) {
      markTestSkipped('Engine binary not found at $dllPath');
      return;
    }
    if (!sigFile.existsSync()) {
      markTestSkipped('Engine signature not found at $sigPath');
      return;
    }

    // 1. Valid signature -> standby.
    controller.verifyEngineIntegrity('eng_liquid_01', workspace);
    expect(controller.activeEngine.status, EngineStatus.standby);

    // 2. Missing signature -> corrupt.
    if (File(sigBackupPath).existsSync()) {
      File(sigBackupPath).deleteSync();
    }
    sigFile.renameSync(sigBackupPath);
    controller.verifyEngineIntegrity('eng_liquid_01', workspace);
    expect(controller.activeEngine.status, EngineStatus.corrupt);

    // 3. Tampered signature -> corrupt.
    sigFile.writeAsStringSync('0' * 128);
    controller.verifyEngineIntegrity('eng_liquid_01', workspace);
    expect(controller.activeEngine.status, EngineStatus.corrupt);

    // Restore the valid signature.
    File(sigBackupPath).renameSync(sigPath);
    controller.verifyEngineIntegrity('eng_liquid_01', workspace);
    expect(controller.activeEngine.status, EngineStatus.standby);
  });
}

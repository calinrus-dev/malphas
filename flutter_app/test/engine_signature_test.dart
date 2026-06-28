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
    final workspace = Directory.current.path;
    final dllPath = Platform.isWindows
        ? '$workspace/malphas_core.dll'
        : '$workspace/libmalphas_core.so';
    final sigPath = '$dllPath.sig';
    final sigBackupPath = '$dllPath.sig.bak';
    final sigFile = File(sigPath);

    // Ensure the binary and a valid signature exist.
    expect(File(dllPath).existsSync(), isTrue,
        reason: 'Engine binary must exist at $dllPath');
    if (!sigFile.existsSync()) {
      fail('Engine signature must exist at $sigPath for this test');
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

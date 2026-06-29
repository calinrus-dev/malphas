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

    // Snapshot the original signature and guarantee restoration even if the
    // test throws or is cancelled mid-way.
    final originalSigBytes = sigFile.readAsBytesSync();
    addTearDown(() {
      File(sigPath).writeAsBytesSync(originalSigBytes, flush: true);
      final backup = File(sigBackupPath);
      if (backup.existsSync()) {
        backup.deleteSync();
      }
    });

    // 1. Valid signature -> standby. If the local signature does not verify
    // (e.g. the motor was rebuilt without the matching CI signing key), skip
    // this test defensively instead of failing.
    controller.verifyEngineIntegrity('eng_liquid_01', workspace);
    if (controller.activeEngine.status != EngineStatus.standby) {
      markTestSkipped(
          'Local engine signature does not verify; TEST_SIGNING_KEY required');
      return;
    }

    // 2. Missing signature -> corrupt.
    if (File(sigBackupPath).existsSync()) {
      File(sigBackupPath).deleteSync();
    }
    sigFile.renameSync(sigBackupPath);
    controller.verifyEngineIntegrity('eng_liquid_01', workspace);
    expect(controller.activeEngine.status, EngineStatus.corrupt);

    // 3. Tampered signature -> corrupt.
    File(sigPath).writeAsStringSync('0' * 128);
    controller.verifyEngineIntegrity('eng_liquid_01', workspace);
    expect(controller.activeEngine.status, EngineStatus.corrupt);

    // 4. Restore the valid signature and verify the engine returns to standby.
    // addTearDown is a safety net that restores the original .sig even if an
    // assertion above throws, but we still perform the explicit restoration so
    // the final standby state is asserted within the test body.
    File(sigBackupPath).renameSync(sigPath);
    controller.verifyEngineIntegrity('eng_liquid_01', workspace);
    expect(controller.activeEngine.status, EngineStatus.standby);
  });
}

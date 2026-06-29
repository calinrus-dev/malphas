import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malphas_app/core/ffi/malphas_bindings.dart';
import 'package:malphas_app/core/services/app_state_persistence_service.dart';
import 'package:malphas_app/features/hub/environment_model.dart';
import 'package:malphas_app/features/package_manager/package_controller.dart';
import 'package:malphas_app/features/workspace/workspace_screen.dart';

void main() {
  late Directory persistenceDir;

  setUp(() {
    persistenceDir = Directory.systemTemp.createTempSync('malphas_ws_persist');
    AppStatePersistenceService().setDocumentsDirectoryOverride(
      persistenceDir.path,
    );
  });

  tearDown(() {
    AppStatePersistenceService().clearDocumentsDirectoryOverride();
    try {
      persistenceDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('WorkspaceScreen auto-loads the bouncing demo package', (
    WidgetTester tester,
  ) async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final bindings = MalphasBindings();
    if (!bindings.isNativeAvailable) {
      markTestSkipped('Native motor is not available in this environment');
      return;
    }

    // Ensure the bouncing_demo package is compiled and registered.
    await PackageController().init();

    final workspace = PackageController().resolveWorkspaceRoot();
    final mhpFile = File('$workspace/examples/bouncing_demo/bouncing_demo.mhp');
    if (!mhpFile.existsSync()) {
      markTestSkipped('bouncing_demo.mhp not found at ${mhpFile.path}');
      return;
    }

    final env = MalphasEnvironment(
      id: 'env_auto_load_test',
      name: 'Auto-load Test',
      accentColor: const Color(0xffe0dcd3),
      packageIds: const ['bouncing_demo'],
    );

    await tester.pumpWidget(
      MaterialApp(home: WorkspaceScreen(environment: env)),
    );

    // Dispose the widget at the end of the test so its Ticker is stopped and
    // the test runner can move on to the next test.
    addTearDown(() async {
      await tester.pumpWidget(Container());
    });

    // Give the async initState auto-load sequence a few frames to complete.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    // The native engine should now be producing render commands.
    final buffer = bindings.commandBuffer;
    expect(
      buffer,
      isNotNull,
      reason: 'Command buffer should be allocated after auto-load',
    );
    final count = bindings.getCommandCount(buffer!);
    expect(
      count,
      greaterThan(0),
      reason: 'Engine should have generated at least one render command',
    );
  });
}

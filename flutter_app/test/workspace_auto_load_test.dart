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
    final mspFile = File('$workspace/examples/bouncing_demo/bouncing_demo.msp');
    final mspSigFile = File('$workspace/examples/bouncing_demo/bouncing_demo.msp.sig');
    if (!mspFile.existsSync()) {
      markTestSkipped('bouncing_demo.msp not found at ${mspFile.path}');
      return;
    }
    if (!mspSigFile.existsSync()) {
      markTestSkipped('bouncing_demo.msp.sig not found; signed package required');
      return;
    }

    final systemPath = _resolveSystemPath(workspace, 'bouncing_demo');
    if (systemPath == null) {
      markTestSkipped('bouncing_demo system (.mxc/.dll/.so/.dylib) not found');
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

    addTearDown(() async {
      await tester.pumpWidget(Container());
    });

    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    // Pulse the engine a few times so the loaded system writes commands.
    for (int i = 0; i < 10; i++) {
      bindings.triggerEnginePulse();
      await tester.pump(const Duration(milliseconds: 16));
    }

    final snapshot = bindings.getFrontBufferSnapshot();
    expect(
      snapshot.count,
      greaterThan(0),
      reason: 'Engine should have generated at least one render command',
    );
  });
}

String? _resolveSystemPath(String workspace, String packId) {
  final exts = Platform.isWindows
      ? ['.mxc', '.dll']
      : Platform.isMacOS
          ? ['.mxc', '.dylib']
          : ['.mxc', '.so'];
  for (final ext in exts) {
    final candidates = [
      '$workspace/flutter_app/motors/$packId$ext',
      '$workspace/examples/$packId/$packId$ext',
      '$workspace/packages/$packId$ext',
      '$workspace/$packId$ext',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return null;
}

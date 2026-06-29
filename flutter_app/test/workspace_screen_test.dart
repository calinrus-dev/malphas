import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malphas_app/core/ffi/malphas_bindings.dart';
import 'package:malphas_app/core/services/app_state_persistence_service.dart';
import 'package:malphas_app/features/hub/environment_model.dart';
import 'package:malphas_app/features/package_manager/package_controller.dart';
import 'package:malphas_app/features/workspace/workspace_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bindings = MalphasBindings();
  late Directory persistenceDir;

  setUp(() {
    persistenceDir = Directory.systemTemp.createTempSync('malphas_ws_persist');
    AppStatePersistenceService().setDocumentsDirectoryOverride(
      persistenceDir.path,
    );
    // Start each test with a clean package registry so the auto-load behavior
    // is deterministic.
    PackageController().reset();
  });

  tearDown(() {
    AppStatePersistenceService().clearDocumentsDirectoryOverride();
    try {
      persistenceDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('WorkspaceScreen shows auto-load error for missing package', (
    WidgetTester tester,
  ) async {
    final env = MalphasEnvironment(
      id: 'env_missing',
      name: 'Missing Pack',
      accentColor: const Color(0xffe0dcd3),
      packageIds: const ['does_not_exist'],
    );

    await tester.pumpWidget(
      MaterialApp(home: WorkspaceScreen(environment: env)),
    );
    addTearDown(() async {
      await tester.pumpWidget(Container());
    });
    // Let the async initState auto-load sequence fail and rebuild with the error overlay.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('AUTO-LOAD ERROR'), findsWidgets);
  });

  testWidgets('WorkspaceScreen renders canvas tabs', (
    WidgetTester tester,
  ) async {
    final env = MalphasEnvironment(
      id: 'env_render',
      name: 'Render Test',
      accentColor: const Color(0xffe0dcd3),
      packageIds: const [],
    );

    await tester.pumpWidget(
      MaterialApp(home: WorkspaceScreen(environment: env)),
    );
    addTearDown(() async {
      await tester.pumpWidget(Container());
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('CANVAS'), findsOneWidget);
    expect(find.text('PACKS'), findsOneWidget);
    expect(find.text('ENGINES'), findsOneWidget);
  });

  testWidgets('WorkspaceScreen auto-loads the default bouncing demo', (
    WidgetTester tester,
  ) async {
    if (!bindings.isNativeAvailable) {
      markTestSkipped('Native motor is not available in this environment');
      return;
    }

    await PackageController().init();

    final workspace = PackageController().resolveWorkspaceRoot();
    final mhpFile = File('$workspace/examples/bouncing_demo/bouncing_demo.mhp');
    if (!mhpFile.existsSync()) {
      markTestSkipped('bouncing_demo.mhp not found');
      return;
    }

    final env = MalphasEnvironment(
      id: 'env_bouncing',
      name: 'Bouncing Demo',
      accentColor: const Color(0xffe0dcd3),
      packageIds: const [],
    );

    await tester.pumpWidget(
      MaterialApp(home: WorkspaceScreen(environment: env)),
    );
    addTearDown(() async {
      await tester.pumpWidget(Container());
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('AUTO-LOAD ERROR'), findsNothing);
  });
}

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malphas_app/core/services/app_state_persistence_service.dart';
import 'package:malphas_app/features/engine_manager/engine_controller.dart';
import 'package:malphas_app/features/hub/environment_model.dart';
import 'package:malphas_app/features/hub/hub_screen.dart';
import 'package:malphas_app/features/package_manager/package_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory persistenceDir;
  late Directory emptyWorkspace;

  setUp(() async {
    persistenceDir =
        Directory.systemTemp.createTempSync('malphas_hub_persistence');
    emptyWorkspace = Directory.systemTemp.createTempSync('malphas_hub_ws');
    AppStatePersistenceService()
        .setDocumentsDirectoryOverride(persistenceDir.path);
    // Ensure a fresh controller state for each test and point to an empty
    // workspace so package scanning does not influence the test.
    PackageController().reset();
    PackageController().setWorkspaceRootOverride(emptyWorkspace.path);
  });

  tearDown(() {
    AppStatePersistenceService().clearDocumentsDirectoryOverride();
    PackageController().clearWorkspaceRootOverride();
    try {
      persistenceDir.deleteSync(recursive: true);
    } catch (_) {}
    try {
      emptyWorkspace.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('HubScreen renders the default sandbox environment',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: MalphasHubScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Malphas Chasis'), findsOneWidget);
    expect(find.text('Malphas Sandbox'), findsOneWidget);
  });

  testWidgets('Creating an environment persists it across reloads',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: MalphasHubScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add_box_outlined));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Test Channel');
    await tester.tap(find.text('CREAR'));
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
          (widget) => widget is Text && widget.data == 'Test Channel'),
      findsOneWidget,
    );

    // Rebuild a fresh HubScreen; the persisted environment must be restored.
    await tester.pumpWidget(const MaterialApp(home: MalphasHubScreen()));
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
          (widget) => widget is Text && widget.data == 'Test Channel'),
      findsOneWidget,
    );
  });

  testWidgets('Pinning an environment is persisted',
      (WidgetTester tester) async {
    final persistence = AppStatePersistenceService();
    persistence.saveEnvironments([
      MalphasEnvironment(
        id: 'env_pinned_test',
        name: 'Pinned Test',
        accentColor: const Color(0xffe0dcd3),
        isPinned: true,
        packageIds: const [],
      ),
    ]);

    await tester.pumpWidget(const MaterialApp(home: MalphasHubScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Pinned Test'), findsOneWidget);

    final stateFile = File('${persistenceDir.path}/malphas_environments.json');
    expect(stateFile.existsSync(), isTrue);
    final jsonList = jsonDecode(stateFile.readAsStringSync()) as List<dynamic>;
    expect(jsonList.first['isPinned'], isTrue);
  });

  testWidgets('EngineController notifies listeners on scan',
      (WidgetTester tester) async {
    final controller = EngineController();
    var notified = false;
    controller.addListener(() => notified = true);

    controller.scanAvailableEngines();

    expect(notified, isTrue);
    expect(controller.getAllEngines(), isNotEmpty);
  });
}

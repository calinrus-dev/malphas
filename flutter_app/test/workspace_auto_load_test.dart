import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malphas_app/core/ffi/malphas_bindings.dart';
import 'package:malphas_app/features/hub/hub_screen.dart';
import 'package:malphas_app/features/package_manager/package_controller.dart';
import 'package:malphas_app/features/workspace/workspace_screen.dart';

void main() {
  testWidgets('WorkspaceScreen auto-loads the bouncing demo package',
      (WidgetTester tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final bindings = MalphasBindings();
    if (!bindings.isNativeAvailable) {
      markTestSkipped('Native motor is not available in this environment');
      return;
    }

    // Ensure the bouncing_demo package is compiled and registered.
    await PackageController().init();

    final env = MalphasEnvironment(
      id: 'env_auto_load_test',
      name: 'Auto-load Test',
      accentColor: const Color(0xffe0dcd3),
      packageIds: const ['bouncing_demo'],
    );

    await tester
        .pumpWidget(MaterialApp(home: WorkspaceScreen(environment: env)));

    // Give the async initState auto-load sequence a few frames to complete.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 50));

    // The native engine should now be producing render commands.
    final buffer = bindings.commandBuffer;
    expect(buffer, isNotNull,
        reason: 'Command buffer should be allocated after auto-load');
    final count = bindings.getCommandCount(buffer!);
    expect(count, greaterThan(0),
        reason: 'Engine should have generated at least one render command');
  });
}

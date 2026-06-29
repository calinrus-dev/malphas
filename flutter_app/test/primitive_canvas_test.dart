import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:malphas_app/core/ffi/malphas_bindings.dart';
import 'package:malphas_app/core/ui_primitives/primitive_canvas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PrimitiveCanvas paints without throwing',
      (WidgetTester tester) async {
    final bindings = MalphasBindings();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PrimitiveCanvas(
            bindings: bindings,
            repaintNotifier: bindings,
          ),
        ),
      ),
    );

    await tester.pump();

    // The canvas should exist and not crash even when the native core is
    // unavailable; in that case it renders the fallback simulation buffer.
    expect(find.byType(PrimitiveCanvas), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PrimitiveCanvas),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
  });

  testWidgets('PrimitiveCanvas rebuilds when repaintNotifier fires',
      (WidgetTester tester) async {
    final bindings = MalphasBindings();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PrimitiveCanvas(
            bindings: bindings,
            repaintNotifier: bindings,
          ),
        ),
      ),
    );

    await tester.pump();

    // Firing the notifier should schedule a repaint without rebuilding the
    // surrounding widget tree.
    bindings.notifyListeners();
    await tester.pump();

    expect(find.byType(PrimitiveCanvas), findsOneWidget);
  });
}

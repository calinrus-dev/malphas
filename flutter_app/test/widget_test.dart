import 'package:flutter_test/flutter_test.dart';
import 'package:malphas_app/main.dart';

void main() {
  testWidgets('Malphas Console smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MalphasConsole());
    expect(find.byType(MalphasConsole), findsOneWidget);
  });
}

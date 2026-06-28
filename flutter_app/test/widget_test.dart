import 'dart:ffi' as dffi;
import 'package:flutter_test/flutter_test.dart';
import 'package:malphas_app/main.dart';
import 'package:malphas_app/core/ffi/types.dart';
import 'package:malphas_app/core/ffi/malphas_bindings.dart';

void main() {
  testWidgets('Malphas Console smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MalphasConsole());
    expect(find.byType(MalphasConsole), findsOneWidget);
  });

  test('ARM memory alignment stress test', () {
    final bindings = MalphasBindings();
    if (!bindings.isNativeAvailable) {
      // Skip if native DLL is not loaded (e.g. during headless environments)
      return;
    }

    // Allocate a large contiguous block of memory
    final totalSize = 256 * 1024;
    final ptr = bindings.malphasAlloc(totalSize);
    expect(ptr, isNot(dffi.nullptr));

    try {
      // Perform 10,000 reads and writes with an artificial odd (unaligned) offset
      // to verify that the FFI bus does not crash on casting/accessing structures
      for (int i = 0; i < 10000; i++) {
        // Offset is odd (e.g., 17, 33, 49, etc.)
        final oddOffset = (i * 16) + 1;
        if (oddOffset + 32 > totalSize) break;
        
        // Access DartRenderCommand from unaligned memory offset
        final cmdPtr = dffi.Pointer<DartRenderCommand>.fromAddress(ptr.address + oddOffset);
        
        // Write fields
        cmdPtr.ref.commandType = 2;
        cmdPtr.ref.layer = 1;
        cmdPtr.ref.x = 100.5 + i;
        cmdPtr.ref.y = 200.5 + i;
        cmdPtr.ref.width = 50.0;
        cmdPtr.ref.height = 50.0;
        cmdPtr.ref.colorRgba = 0xFF112233;
        
        // Read and assert values
        expect(cmdPtr.ref.commandType, equals(2));
        expect(cmdPtr.ref.layer, equals(1));
        expect(cmdPtr.ref.x, equals(100.5 + i));
        expect(cmdPtr.ref.y, equals(200.5 + i));
        expect(cmdPtr.ref.width, equals(50.0));
        expect(cmdPtr.ref.height, equals(50.0));
        expect(cmdPtr.ref.colorRgba, equals(0xFF112233));
      }
    } finally {
      bindings.malphasFree(ptr, totalSize);
    }
  });
}

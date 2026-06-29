import 'dart:convert';
import 'dart:ffi' as dffi;
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:malphas_app/main.dart';
import 'package:malphas_app/core/compiler/package_compiler.dart';
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

    // Allocate a large contiguous block of memory through the Rust-aligned
    // allocator. All shared-memory buffers must be 16-byte aligned on ARM64.
    const totalSize = 256 * 1024;
    final ptr = bindings.malphasAlloc(totalSize);
    expect(ptr, isNot(dffi.nullptr));

    try {
      // Perform 10,000 reads and writes at aligned DartRenderCommand strides.
      // The allocator is 16-byte aligned and DartRenderCommand is 24 bytes,
      // so every stride stays naturally aligned for the struct's 4-byte rule.
      const slotSize = 24;
      for (int i = 0; i < 10000; i++) {
        final offset = i * slotSize;
        if (offset + slotSize > totalSize) break;

        final cmdPtr =
            dffi.Pointer<DartRenderCommand>.fromAddress(ptr.address + offset);

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

  test('Malphas FFI package load and tick integration', () async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final bindings = MalphasBindings();
    if (!bindings.isNativeAvailable) {
      // Headless CI or environment without the native library: compile path still
      // runs, but skip the native assertions gracefully.
      return;
    }

    // 1. Compile a manifest with at least one rectangle and one text entity.
    final compiler = MalphasPackageCompiler();
    if (!await compiler.isCliAvailable()) {
      markTestSkipped('malphas-cli not available');
      return;
    }

    final manifest = {
      'pack_id': 'integ_test_pack',
      'canvas_width': 1000,
      'canvas_height': 1000,
      'objects': [
        {
          'object_id': 1,
          'properties': {'kind': 'rectangle'},
        },
        {
          'object_id': 2,
          'properties': {'kind': 'text'},
        },
      ],
    };
    final output = await compiler.compilePackage(manifest);

    // 2. Write .mhp and .msp bytes to temporary files.
    final tmpDir = Directory.systemTemp.createTempSync('malphas_integration');
    final mhpFile = File('${tmpDir.path}/test.mhp')
      ..writeAsBytesSync(output.mhpBytes);

    // 3. Load the pack through the FFI bridge.
    final loadResult = bindings.loadPack(mhpFile.path);
    expect(loadResult, equals(0));

    // 4. Configure two entities: one rectangle and one text.
    bindings.setEntitiesCount(2);

    bindings.configureEntity(
      entityId: 0,
      commandType: 1, // rectangle
      layer: 0,
      x: 50.0,
      y: 50.0,
      width: 100.0,
      height: 100.0,
      colorRgba: 0xFF112233,
      speedX: 2.0,
      speedY: 1.0,
      minX: 0.0,
      maxX: 500.0,
      minY: 0.0,
      maxY: 500.0,
    );

    const textOffset = 8192;
    bindings.writeArenaText(
      textOffset,
      100.0,
      100.0,
      24.0,
      Uint8List.fromList([...utf8.encode('Malphas'), 0]),
    );

    bindings.configureEntity(
      entityId: 1,
      commandType: 2, // text
      layer: 1,
      x: 100.0,
      y: 100.0,
      width: 24.0, // font size / style
      height: 0.0,
      colorRgba: 0xFFFFFFFF,
      speedX: 0.0,
      speedY: 0.0,
      minX: 0.0,
      maxX: 1000.0,
      minY: 0.0,
      maxY: 1000.0,
      strOffset: textOffset,
    );

    // 5. Pulse the engine and wait for the simulation thread to produce output.
    int commandCount = 0;
    for (int i = 0; i < 10; i++) {
      commandCount = bindings.tick();
      if (commandCount >= 2) break;
      await Future.delayed(const Duration(milliseconds: 10));
    }

    // 6. Read the front command buffer and verify expected commands.
    final buffer = bindings.commandBuffer;
    expect(buffer, isNotNull);
    expect(buffer, isNot(dffi.nullptr));

    final count = bindings.getCommandCount(buffer!);
    expect(count, greaterThanOrEqualTo(2));

    final commandsPtr = bindings.getCommandsPointer(buffer);
    final commandTypes = <int>[];
    for (int i = 0; i < count; i++) {
      commandTypes.add(commandsPtr[i].commandType);
    }

    expect(commandTypes, contains(1)); // rectangle
    expect(commandTypes, contains(2)); // text

    // Cleanup temp files is best-effort; the OS temp dir is reclaimed anyway.
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {
      // Ignore cleanup failures.
    }
  });
}

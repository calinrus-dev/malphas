import 'dart:ffi' as dffi;
import 'dart:io';
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

    // Allocate a large contiguous block of memory through the Rust-aligned
    // allocator. All shared-memory buffers must be 64-byte aligned on ARM64.
    const totalSize = 256 * 1024;
    final ptr = bindings.malphasAlloc(totalSize);
    expect(ptr, isNot(dffi.nullptr));
    expect(ptr.address % 64, equals(0));

    try {
      // Perform 10,000 reads and writes at aligned DartRenderCommand strides.
      // The allocator is 64-byte aligned and DartRenderCommand is 24 bytes,
      // so every stride stays naturally aligned for the struct's 4-byte rule.
      const slotSize = 24;
      for (int i = 0; i < 10000; i++) {
        final offset = i * slotSize;
        if (offset + slotSize > totalSize) break;

        final cmdPtr = dffi.Pointer<DartRenderCommand>.fromAddress(
          ptr.address + offset,
        );

        cmdPtr.ref.commandType = 2;
        cmdPtr.ref.layer = 1;
        cmdPtr.ref.x = 100.5 + i;
        cmdPtr.ref.y = 200.5 + i;
        cmdPtr.ref.width = 50.0;
        cmdPtr.ref.height = 50.0;
        cmdPtr.ref.colorRgba = 0xFF112233;

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
      return;
    }

    final workspace = _findWorkspaceRoot();
    final mspFile = File('$workspace/examples/bouncing_demo/bouncing_demo.msp');
    final systemPath = _resolveSystemPath(workspace, 'bouncing_demo');

    if (!mspFile.existsSync()) {
      markTestSkipped('bouncing_demo.msp not found at ${mspFile.path}');
      return;
    }
    if (systemPath == null) {
      markTestSkipped('bouncing_demo system not found');
      return;
    }

    // 1. Initialise the engine and allocate the bridge/buffers.
    expect(bindings.initEngine(), equals(0));

    // 2. Load the Silver Platter and the .mxc system.
    expect(bindings.loadMsp(mspFile.path), equals(0));
    expect(bindings.loadSystem(systemPath), equals(0));

    // 3. Pulse the engine and read the front buffer directly.
    for (int i = 0; i < 20; i++) {
      bindings.triggerEnginePulse();
      await Future.delayed(const Duration(milliseconds: 10));
    }

    final count = bindings.commandCount;
    expect(count, greaterThan(0));

    final commandsPtr = bindings.commandsPointer;
    expect(commandsPtr, isNot(dffi.nullptr));
    final commandTypes = <int>[];
    for (int i = 0; i < count; i++) {
      commandTypes.add(commandsPtr[i].commandType);
    }

    // bouncing_demo emits rectangle render commands.
    expect(commandTypes, contains(1));

    bindings.shutdownEngine();
  });
}

String _findWorkspaceRoot() {
  var current = Directory.current;
  for (var i = 0; i < 8; i++) {
    final cargoToml = File('${current.path}/Cargo.toml');
    if (cargoToml.existsSync()) {
      try {
        final contents = cargoToml.readAsStringSync();
        if (contents.contains('[workspace]')) return current.path;
      } catch (_) {}
    }
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return current.path;
}

String? _resolveSystemPath(String workspace, String packId) {
  final exts = Platform.isWindows
      ? ['.mxc', '.dll']
      : Platform.isMacOS
          ? ['.mxc', '.dylib']
          : ['.mxc', '.so'];
  for (final ext in exts) {
    final candidates = [
      '$workspace/examples/$packId/$packId$ext',
      '$workspace/packages/$packId$ext',
      '$workspace/$packId$ext',
      '$workspace/flutter_app/motors/$packId$ext',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return null;
}

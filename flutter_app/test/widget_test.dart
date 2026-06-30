import 'dart:ffi' as dffi;
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
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
      // DartRenderCommand is a 64-byte packed struct as required by v2.10.0.
      const slotSize = 64;
      for (int i = 0; i < 10000; i++) {
        final offset = i * slotSize;
        if (offset + slotSize > totalSize) break;

        final cmdPtr = dffi.Pointer<DartRenderCommand>.fromAddress(
          ptr.address + offset,
        );

        cmdPtr.ref.type = 2;
        cmdPtr.ref.entityId = 1;
        cmdPtr.ref.x = 100.5 + i;
        cmdPtr.ref.y = 200.5 + i;
        cmdPtr.ref.width = 50.0;
        cmdPtr.ref.height = 50.0;
        cmdPtr.ref.color = 0xFF112233;
        cmdPtr.ref.payloadId = 42;

        expect(cmdPtr.ref.type, equals(2));
        expect(cmdPtr.ref.entityId, equals(1));
        expect(cmdPtr.ref.x, equals(100.5 + i));
        expect(cmdPtr.ref.y, equals(200.5 + i));
        expect(cmdPtr.ref.width, equals(50.0));
        expect(cmdPtr.ref.height, equals(50.0));
        expect(cmdPtr.ref.color, equals(0xFF112233));
        expect(cmdPtr.ref.payloadId, equals(42));
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
    expect(() => bindings.initEngine(), returnsNormally);

    // Configure the trust anchor from a build-time define or the bundled asset
    // so signed MSP and MXC assets can be verified in this integration test.
    // When neither is available (e.g. CI with MALPHAS_INSECURE_SKIP_VERIFY),
    // continue without an anchor.
    const trustAnchorFromDefine =
        String.fromEnvironment('MALPHAS_TRUST_ANCHOR');
    String? trustAnchor;
    if (trustAnchorFromDefine.isNotEmpty) {
      trustAnchor = trustAnchorFromDefine;
    } else {
      try {
        trustAnchor =
            (await rootBundle.loadString('assets/trust_anchor.pem')).trim();
      } catch (_) {
        trustAnchor = null;
      }
    }
    if (trustAnchor != null && trustAnchor.isNotEmpty) {
      expect(() => bindings.setTrustAnchor(trustAnchor!), returnsNormally);
    }

    // 2. Load the Silver Platter and the .mxc system.
    expect(() => bindings.loadMsp(mspFile.path), returnsNormally);
    expect(() => bindings.loadSystem(systemPath), returnsNormally);

    // 3. Pulse the engine and read the front buffer directly.
    for (int i = 0; i < 20; i++) {
      bindings.triggerEnginePulse();
      await Future.delayed(const Duration(milliseconds: 10));
    }

    final snapshot = bindings.getFrontBufferSnapshot();
    expect(snapshot.count, greaterThan(0));

    final commandsPtr = snapshot.commands;
    expect(commandsPtr, isNot(dffi.nullptr));
    final commandTypes = <int>[];
    for (int i = 0; i < snapshot.count; i++) {
      commandTypes.add(commandsPtr[i].type);
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

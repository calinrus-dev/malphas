import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A widgets test is required so the test runner reports this file in the
  // aggregated suite output; the unit test below performs the actual parsing.
  testWidgets('MSP parser file is discoverable', (WidgetTester tester) async {
    expect(true, isTrue);
  });

  test('Parses compiled bouncing_demo.msp header and verifies entity count',
      () {
    final workspace = _findWorkspaceRoot();
    final mspFile = File('$workspace/examples/bouncing_demo/bouncing_demo.msp');

    if (!mspFile.existsSync()) {
      markTestSkipped('bouncing_demo.msp not found at ${mspFile.path}');
      return;
    }

    final bytes = mspFile.readAsBytesSync();
    expect(bytes.length, greaterThanOrEqualTo(56));

    // Verify magic header: 'MLPS'
    expect(bytes[0], 0x4D);
    expect(bytes[1], 0x4C);
    expect(bytes[2], 0x50);
    expect(bytes[3], 0x53);

    final data = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    final version = data.getUint32(4, Endian.little);
    expect(version, greaterThanOrEqualTo(1));

    final entitiesTableOffset = data.getUint32(8, Endian.little);
    final entitiesCount = data.getUint32(12, Endian.little);
    final payloadSectionOffset = data.getUint32(16, Endian.little);
    final payloadSectionSize = data.getUint32(20, Endian.little);

    expect(entitiesTableOffset, lessThanOrEqualTo(bytes.length));
    expect(payloadSectionOffset, lessThanOrEqualTo(bytes.length));
    expect(
      payloadSectionOffset + payloadSectionSize,
      lessThanOrEqualTo(bytes.length),
    );

    // bouncing_demo manifest declares two entities with ids 0 and 1.
    expect(entitiesCount, greaterThanOrEqualTo(2));

    const descriptorSize = 64;
    final entityIds = <int>{};
    for (int i = 0; i < entitiesCount; i++) {
      final entryOffset = entitiesTableOffset + (i * descriptorSize);
      if (entryOffset + descriptorSize > bytes.length) break;
      entityIds.add(data.getUint32(entryOffset, Endian.little));
    }

    expect(entityIds, containsAll(<int>[0, 1]));
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

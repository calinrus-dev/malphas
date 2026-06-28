import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';

class CompileOutput {
  final Uint8List mhpBytes;
  final Uint8List mspBytes;
  CompileOutput(this.mhpBytes, this.mspBytes);
}

class MalphasPackageCompiler {
  Uint8List align16(Uint8List data) {
    final rem = data.length % 16;
    if (rem == 0) return data;
    final padSize = 16 - rem;
    final builder = BytesBuilder();
    builder.add(data);
    builder.add(Uint8List(padSize));
    return builder.toBytes();
  }

  Future<CompileOutput> compilePackage(Map<String, dynamic> manifest) async {
    // 1. Generate Font Atlas (measure and render characters ASCII 0-255)
    final fontData = await compileFontAtlas();
    final metricsBytes = align16(fontData['metrics']!); // 4096 bytes
    final pixelsBytes = align16(fontData['pixels']!);   // 262144 bytes

    // 2. Compile VM Bytecode for movement physics & generate standalone .msp
    final bytecodeBytes = align16(assembleBouncingScript());
    final mspBytes = compileMsp(bytecodeBytes);

    // 3. Assemble Objects Table (32 bytes per entry)
    final jumpBuilder = BytesBuilder();
    final List<dynamic> objects = manifest['objects'] as List<dynamic>? ?? [];
    
    // Skin and properties binary data pool
    final dataPoolBuilder = BytesBuilder();
    
    for (final obj in objects) {
      final int objId = obj['object_id'] as int? ?? 0;
      
      // Write properties JSON to data pool
      final propJson = jsonEncode(obj['properties'] ?? {});
      final propBytes = align16(utf8.encode(propJson));
      final propOffset = dataPoolBuilder.length;
      dataPoolBuilder.add(propBytes);
      
      // Write placeholder skin block (256 bytes) to data pool
      final skinBytes = align16(Uint8List(256));
      final skinOffset = dataPoolBuilder.length;
      dataPoolBuilder.add(skinBytes);
      
      // Object Table entry structure (exactly 32 bytes, 16-byte aligned)
      final entry = ByteData(32);
      entry.setUint32(0, objId, Endian.little);
      entry.setUint32(4, propOffset, Endian.little);
      entry.setUint32(8, propBytes.length, Endian.little);
      entry.setUint32(12, skinOffset, Endian.little);
      entry.setUint32(16, skinBytes.length, Endian.little);
      // bytes 20-31: padding (12 bytes)
      jumpBuilder.add(entry.buffer.asUint8List());
    }

    final jumpTableBytes = align16(jumpBuilder.toBytes());
    final dataPoolBytes = align16(dataPoolBuilder.toBytes());

    // 4. Calculate layout offsets
    final headerSize = 112;
    final fontMetricsOffset = headerSize;
    final fontAtlasOffset = fontMetricsOffset + metricsBytes.length;
    final objectsTableOffset = fontAtlasOffset + pixelsBytes.length;
    final skinsOffset = objectsTableOffset + jumpTableBytes.length;
    final embeddedMspOffset = skinsOffset + dataPoolBytes.length;
    final embeddedMspSize = mspBytes.length;

    // 5. Assemble Payload (everything after the header)
    final payloadBuilder = BytesBuilder();
    payloadBuilder.add(metricsBytes);
    payloadBuilder.add(pixelsBytes);
    payloadBuilder.add(jumpTableBytes);
    payloadBuilder.add(dataPoolBytes);
    payloadBuilder.add(mspBytes);
    final payloadBytes = payloadBuilder.toBytes();

    // 6. Calculate Checksum over payload
    final checksum = sha256.convert(payloadBytes).bytes;

    // 7. Write MhpHeader (112 bytes)
    final header = ByteData(headerSize);
    // 'MLPH' magic
    header.setUint8(0, 0x4D); // 'M'
    header.setUint8(1, 0x4C); // 'L'
    header.setUint8(2, 0x50); // 'P'
    header.setUint8(3, 0x48); // 'H'
    
    header.setUint32(4, 1, Endian.little); // version
    header.setUint64(8, (headerSize + payloadBytes.length).toUnsigned(64), Endian.little); // total_size
    
    // Inject 32-byte checksum (offsets 16-47)
    for (int i = 0; i < 32; i++) {
      header.setUint8(16 + i, checksum[i]);
    }

    // pack_id (offsets 48-63)
    final packIdStr = manifest['pack_id'] as String? ?? 'pack_custom_01';
    final packIdBytes = utf8.encode(packIdStr);
    for (int i = 0; i < 16; i++) {
      header.setUint8(48 + i, i < packIdBytes.length ? packIdBytes[i] : 0);
    }

    header.setUint16(64, 1000, Endian.little); // canvas_width
    header.setUint16(66, 1000, Endian.little); // canvas_height
    
    header.setUint32(68, fontMetricsOffset, Endian.little);
    header.setUint32(72, fontAtlasOffset, Endian.little);
    
    header.setUint32(76, objectsTableOffset, Endian.little);
    header.setUint32(80, objects.length, Endian.little); // objects_table_count
    
    header.setUint32(84, skinsOffset, Endian.little);
    header.setUint32(88, dataPoolBytes.length, Endian.little); // skins_size
    
    header.setUint32(92, 1, Endian.little); // has_embedded_msp = 1
    header.setUint32(96, embeddedMspOffset, Endian.little);
    header.setUint32(100, embeddedMspSize, Endian.little);
    // bytes 104-111: padding

    final mhpBuilder = BytesBuilder();
    mhpBuilder.add(header.buffer.asUint8List());
    mhpBuilder.add(payloadBytes);
    final mhpBytes = mhpBuilder.toBytes();

    return CompileOutput(mhpBytes, mspBytes);
  }

  Uint8List compileMsp(Uint8List bytecodeBytes) {
    final headerSize = 64;
    
    // Calculate Checksum over bytecode payload
    final checksum = sha256.convert(bytecodeBytes).bytes;

    final header = ByteData(headerSize);
    // 'MLPS' magic
    header.setUint8(0, 0x4D); // 'M'
    header.setUint8(1, 0x4C); // 'L'
    header.setUint8(2, 0x50); // 'P'
    header.setUint8(3, 0x53); // 'S'
    
    header.setUint32(4, 1, Endian.little); // version
    
    // Inject 32-byte checksum (offsets 8-39)
    for (int i = 0; i < 32; i++) {
      header.setUint8(8 + i, checksum[i]);
    }
    
    header.setUint32(40, bytecodeBytes.length, Endian.little);
    header.setUint32(44, 0, Endian.little); // entry_point
    // bytes 48-63: padding (16 bytes)

    final mspBuilder = BytesBuilder();
    mspBuilder.add(header.buffer.asUint8List());
    mspBuilder.add(bytecodeBytes);
    return mspBuilder.toBytes();
  }

  Future<Map<String, Uint8List>> compileFontAtlas() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, 512, 512));
    final bgPaint = Paint()..color = const Color(0x00000000);
    canvas.drawRect(Rect.fromLTWH(0, 0, 512, 512), bgPaint);

    final metricsTable = ByteData(4096);
    
    for (int charCode = 0; charCode < 256; charCode++) {
      final int cellX = charCode % 16;
      final int cellY = charCode ~/ 16;
      final double px = cellX * 32.0;
      final double py = cellY * 32.0;

      final charStr = String.fromCharCode(charCode);
      final textPainter = TextPainter(
        text: TextSpan(
          text: charStr,
          style: const TextStyle(
            fontSize: 24,
            fontFamily: 'Courier',
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      
      textPainter.layout();
      
      final double dx = px + (32.0 - textPainter.width) / 2.0;
      final double dy = py + (32.0 - textPainter.height) / 2.0;
      
      textPainter.paint(canvas, Offset(dx, dy));

      final int mx = dx.toInt();
      final int my = dy.toInt();
      final int mw = textPainter.width.toInt();
      final int mh = textPainter.height.toInt();
      final int mXOffset = ((32.0 - textPainter.width) / 2.0).toInt();
      final int mAdvance = textPainter.width.toInt() > 0 ? textPainter.width.toInt() : 16;

      final int offset = charCode * 16;
      metricsTable.setUint16(offset + 0, charCode, Endian.little);
      metricsTable.setUint16(offset + 2, mx, Endian.little);
      metricsTable.setUint16(offset + 4, my, Endian.little);
      metricsTable.setUint16(offset + 6, mw, Endian.little);
      metricsTable.setUint16(offset + 8, mh, Endian.little);
      metricsTable.setInt16(offset + 10, mXOffset, Endian.little);
      metricsTable.setUint16(offset + 12, mAdvance, Endian.little);
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(512, 512);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final rgbaBytes = byteData!.buffer.asUint8List();

    final a8Bytes = Uint8List(512 * 512);
    for (int i = 0; i < 512 * 512; i++) {
      a8Bytes[i] = rgbaBytes[i * 4]; // Extract R channel intensity
    }

    return {
      'metrics': metricsTable.buffer.asUint8List(),
      'pixels': a8Bytes,
    };
  }

  Uint8List assembleBouncingScript() {
    final bytes = BytesBuilder();
    
    void writeInst(int op, int arg1, int val) {
      bytes.addByte(op);
      bytes.addByte(arg1);
      bytes.addByte((val >> 8) & 0xFF);
      bytes.addByte(val & 0xFF);
    }

    // 1. READ_ARENA_F32(reg0, offset=4) -> read X
    writeInst(0x05, 0, 4);
    // 2. READ_ARENA_F32(reg1, offset=8) -> read Y
    writeInst(0x05, 1, 8);
    // 3. READ_ARENA_F32(reg2, offset=24) -> read speed_x
    writeInst(0x05, 2, 24);
    // 4. READ_ARENA_F32(reg3, offset=28) -> read speed_y
    writeInst(0x05, 3, 28);
    // 5. ADD_REG(reg0, reg2) -> X += speed_x
    writeInst(0x02, 0, 2);
    // 6. ADD_REG(reg1, reg3) -> Y += speed_y
    writeInst(0x02, 1, 3);

    // Check min_x:
    // 7. READ_ARENA_F32(reg4, offset=32) -> min_x (e.g. 50.0)
    writeInst(0x05, 4, 32);
    // 8. JMP_LT(reg4, reg0, instr_idx=13) -> if min_x < X, skip reverse
    writeInst(0x08, 4, (0 << 8) | 13);
    
    // Reverse speed_x:
    // 9. LOAD_REG_CONST(reg5, 0)
    writeInst(0x01, 5, 0);
    // 10. LOAD_REG_CONST(reg6, 1)
    writeInst(0x01, 6, 1);
    // 11. SUB_REG(reg5, reg6) -> reg5 = -1
    writeInst(0x03, 5, 6);
    // 12. MUL_REG(reg2, reg5) -> speed_x = -speed_x
    writeInst(0x0B, 2, 5);

    // Check max_x (instruction 13):
    // 13. READ_ARENA_F32(reg4, offset=36) -> max_x (e.g. 900.0)
    writeInst(0x05, 4, 36);
    // 14. JMP_LT(reg0, reg4, instr_idx=19) -> if X < max_x, skip reverse
    writeInst(0x08, 0, (4 << 8) | 19);
    
    // Reverse speed_x:
    // 15. LOAD_REG_CONST(reg5, 0)
    writeInst(0x01, 5, 0);
    // 16. LOAD_REG_CONST(reg6, 1)
    writeInst(0x01, 6, 1);
    // 17. SUB_REG(reg5, reg6) -> reg5 = -1
    writeInst(0x03, 5, 6);
    // 18. MUL_REG(reg2, reg5) -> speed_x = -speed_x
    writeInst(0x0B, 2, 5);

    // Check min_y (instruction 19):
    // 19. READ_ARENA_F32(reg4, offset=40) -> min_y (e.g. 50.0)
    writeInst(0x05, 4, 40);
    // 20. JMP_LT(reg4, reg1, instr_idx=25) -> if min_y < Y, skip reverse
    writeInst(0x08, 4, (1 << 8) | 25);
    
    // Reverse speed_y:
    // 21. LOAD_REG_CONST(reg5, 0)
    writeInst(0x01, 5, 0);
    // 22. LOAD_REG_CONST(reg6, 1)
    writeInst(0x01, 6, 1);
    // 23. SUB_REG(reg5, reg6) -> reg5 = -1
    writeInst(0x03, 5, 6);
    // 24. MUL_REG(reg3, reg5) -> speed_y = -speed_y
    writeInst(0x0B, 3, 5);

    // Check max_y (instruction 25):
    // 25. READ_ARENA_F32(reg4, offset=44) -> max_y (e.g. 900.0)
    writeInst(0x05, 4, 44);
    // 26. JMP_LT(reg1, reg4, instr_idx=31) -> if Y < max_y, skip reverse
    writeInst(0x08, 1, (4 << 8) | 31);
    
    // Reverse speed_y:
    // 27. LOAD_REG_CONST(reg5, 0)
    writeInst(0x01, 5, 0);
    // 28. LOAD_REG_CONST(reg6, 1)
    writeInst(0x01, 6, 1);
    // 29. SUB_REG(reg5, reg6) -> reg5 = -1
    writeInst(0x03, 5, 6);
    // 30. MUL_REG(reg3, reg5) -> speed_y = -speed_y
    writeInst(0x0B, 3, 5);

    // Write back updated entity properties
    // 31. WRITE_ARENA_F32(offset=4, reg0) -> X
    writeInst(0x04, 0, 4);
    // 32. WRITE_ARENA_F32(offset=8, reg1) -> Y
    writeInst(0x04, 1, 8);
    // 33. WRITE_ARENA_F32(offset=24, reg2) -> speed_x
    writeInst(0x04, 2, 24);
    // 34. WRITE_ARENA_F32(offset=28, reg3) -> speed_y
    writeInst(0x04, 3, 28);
    // 35. HALT
    writeInst(0x00, 0, 0);

    return bytes.toBytes();
  }
}

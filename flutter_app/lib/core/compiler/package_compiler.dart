import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class MalphasPackageCompiler {
  Future<Uint8List> compilePackage(Map<String, dynamic> manifest) async {
    // 1. Serialize manifest JSON
    final manifestJsonStr = jsonEncode(manifest);
    final manifestBytes = utf8.encode(manifestJsonStr);

    // 2. Generate Font Atlas (measure and render characters ASCII 0-255)
    final fontData = await compileFontAtlas();
    final metricsBytes = fontData['metrics']!;
    final pixelsBytes = fontData['pixels']!;

    // 3. Assemble VM Bytecode for movement physics
    final bytecodeBytes = assembleBouncingScript();

    // 4. Generate Table of Jumps & Free Arena
    final jumpBuilder = BytesBuilder();
    final arenaBuilder = BytesBuilder();
    
    final List<dynamic> objects = manifest['objects'] as List<dynamic>? ?? [];
    
    for (final obj in objects) {
      final int objId = obj['object_id'] as int? ?? 0;
      
      // Write custom metadata to arenaBuilder
      final metaOffset = arenaBuilder.length;
      final metaJson = jsonEncode(obj['properties'] ?? {});
      final metaBytes = utf8.encode(metaJson);
      arenaBuilder.add(metaBytes);
      
      // Write skins (A simple dummy raw pixel skin block for now)
      final skinsOffset = arenaBuilder.length;
      final skinsBytes = Uint8List(256 * 256 * 4); // 256KB placeholder raw image
      arenaBuilder.add(skinsBytes);
      final skinsSize = skinsBytes.length;
      
      // Table entry
      final entry = ByteData(14);
      entry.setUint16(0, objId, Endian.little);
      entry.setUint32(2, metaOffset, Endian.little);
      entry.setUint32(6, skinsOffset, Endian.little);
      entry.setUint32(10, skinsSize, Endian.little);
      jumpBuilder.add(entry.buffer.asUint8List());
    }

    // Header size is 32 bytes
    final headerSize = 32;
    final manifestOffset = headerSize;
    final fontMetricsOffset = manifestOffset + manifestBytes.length;
    final fontAtlasOffset = fontMetricsOffset + metricsBytes.length;
    final tableOfJumpsOffset = fontAtlasOffset + pixelsBytes.length;
    final bytecodeOffset = tableOfJumpsOffset + jumpBuilder.length;
    // final freeArenaOffset = bytecodeOffset + bytecodeBytes.length;

    final header = ByteData(headerSize);
    // 'MLPH' magic
    header.setUint8(0, 0x4D); // 'M'
    header.setUint8(1, 0x4C); // 'L'
    header.setUint8(2, 0x50); // 'P'
    header.setUint8(3, 0x48); // 'H'
    
    header.setUint32(4, manifestBytes.length, Endian.little);
    header.setUint32(8, fontMetricsOffset, Endian.little);
    header.setUint32(12, fontAtlasOffset, Endian.little);
    header.setUint32(16, tableOfJumpsOffset, Endian.little);
    header.setUint32(20, jumpBuilder.length, Endian.little);
    header.setUint32(24, bytecodeOffset, Endian.little);
    header.setUint32(28, bytecodeBytes.length, Endian.little);

    final packBytes = BytesBuilder();
    packBytes.add(header.buffer.asUint8List());
    packBytes.add(manifestBytes);
    packBytes.add(metricsBytes);
    packBytes.add(pixelsBytes);
    packBytes.add(jumpBuilder.toBytes());
    packBytes.add(bytecodeBytes);
    packBytes.add(arenaBuilder.toBytes());

    return packBytes.toBytes();
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

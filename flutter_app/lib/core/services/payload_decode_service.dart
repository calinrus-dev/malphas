import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/flat_models.dart';

/// Result of decoding an [EntityPayload] off the main thread.
///
/// Image decoding (turning bytes into a [ui.Image]) still happens on the main
/// thread because Flutter's image codecs must run there.  This service only
/// performs I/O and lightweight parsing inside the isolate.
class DecodedPayload {
  final PayloadType type;
  final String name;
  final String? path;
  final Uint8List? bytes;
  final String? textPreview;

  const DecodedPayload({
    required this.type,
    required this.name,
    this.path,
    this.bytes,
    this.textPreview,
  });
}

enum PayloadType { image, json, text, binary }

/// Lightweight service that resolves payload files in a Dart [Isolate].
class PayloadDecodeService {
  const PayloadDecodeService();

  /// Reads and classifies the payload referenced by [payload].
  ///
  /// The file read (and JSON parsing when applicable) runs in [Isolate.run]
  /// so the UI isolate stays responsive while scrolling through a large grid.
  Future<DecodedPayload> decodePayload(EntityPayload payload) async {
    final path = payload.assetPath;
    if (path.isEmpty || path == 'none') {
      return DecodedPayload(
        type: PayloadType.binary,
        name: payload.name,
        textPreview: 'No asset',
      );
    }

    return Isolate.run(() => _decodeInIsolate(
          name: payload.name,
          path: path,
        ));
  }

  static DecodedPayload _decodeInIsolate({
    required String name,
    required String path,
  }) {
    var file = File(path);
    if (!file.existsSync()) {
      // Try resolving against the repository root if the relative path fails.
      final current = Directory.current.path;
      file = File('$current/$path');
    }

    if (!file.existsSync()) {
      return DecodedPayload(
        type: PayloadType.binary,
        name: name,
        path: path,
        textPreview: 'File not found',
      );
    }

    try {
      final bytes = file.readAsBytesSync();
      final lower = path.toLowerCase();

      if (lower.endsWith('.json')) {
        final text = utf8.decode(bytes, allowMalformed: true);
        dynamic json;
        try {
          json = jsonDecode(text);
        } catch (_) {}
        final preview = json != null
            ? const JsonEncoder.withIndent('  ')
                .convert(json)
                .split('\n')
                .take(8)
                .join('\n')
            : text.length > 200
                ? '${text.substring(0, 200)}...'
                : text;
        return DecodedPayload(
          type: PayloadType.json,
          name: name,
          path: path,
          bytes: bytes,
          textPreview: preview,
        );
      }

      if (lower.endsWith('.png') ||
          lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.gif') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.bmp')) {
        return DecodedPayload(
          type: PayloadType.image,
          name: name,
          path: path,
          bytes: bytes,
        );
      }

      if (lower.endsWith('.txt') || lower.endsWith('.md')) {
        final text = utf8.decode(bytes, allowMalformed: true);
        return DecodedPayload(
          type: PayloadType.text,
          name: name,
          path: path,
          bytes: bytes,
          textPreview:
              text.length > 200 ? '${text.substring(0, 200)}...' : text,
        );
      }

      return DecodedPayload(
        type: PayloadType.binary,
        name: name,
        path: path,
        bytes: bytes,
        textPreview: '${bytes.length} bytes',
      );
    } catch (e) {
      return DecodedPayload(
        type: PayloadType.binary,
        name: name,
        path: path,
        textPreview: 'Decode error: $e',
      );
    }
  }
}

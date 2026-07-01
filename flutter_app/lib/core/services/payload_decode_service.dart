import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../models/flat_models.dart';

/// Classification of a payload after decoding.
enum PayloadType { image, json, text, binary, audio }

/// Result of decoding an [EntityPayload] off the main thread.
///
/// Image byte data is returned here; conversion to [ui.Image] must still happen
/// on the main thread because Flutter's image codecs are UI-isolate bound.
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

/// Lightweight service that resolves payload files in a Dart [Isolate].
///
/// Results are cached in an LRU cache (max 100 items) so fast scrolling through
/// a large payload grid does not repeat I/O work.
class PayloadDecodeService {
  static const int _maxCacheSize = 100;
  static const int _maxCacheBytes = 64 * 1024 * 1024; // 64 MB
  static final LinkedHashMap<int, DecodedPayload> _cache =
      LinkedHashMap<int, DecodedPayload>();
  static int _cacheBytes = 0;

  const PayloadDecodeService();

  /// Reads and classifies the payload referenced by [payload].
  ///
  /// The file read and classification run in [Isolate.run]. The result is
  /// cached by payload id so repeated lookups are cheap.
  Future<DecodedPayload> decodePayload(EntityPayload payload) async {
    final cached = _cache[payload.id];
    if (cached != null) {
      _promote(payload.id);
      return cached;
    }

    final path = payload.assetPath;
    if (path.isEmpty || path == 'none') {
      final result = DecodedPayload(
        type: PayloadType.binary,
        name: payload.name,
        textPreview: 'No asset',
      );
      _put(payload.id, result);
      return result;
    }

    final result = await Isolate.run(() => _decodeInIsolate(
          name: payload.name,
          path: path,
        ));
    _put(payload.id, result);
    return result;
  }

  /// Clears the decode cache and releases the byte accounting.
  void clearCache() {
    _cache.clear();
    _cacheBytes = 0;
  }

  void _promote(int id) {
    final value = _cache.remove(id);
    if (value != null) _cache[id] = value;
  }

  static int _payloadSizeBytes(DecodedPayload payload) {
    if (payload.bytes != null) return payload.bytes!.length;
    if (payload.textPreview != null) return payload.textPreview!.length * 2;
    return 64;
  }

  void _put(int id, DecodedPayload payload) {
    final incoming = _payloadSizeBytes(payload);

    // Evict oldest entries until both item count and byte budget allow the new
    // payload. This keeps the cache under a predictable RAM cap.
    while (_cache.isNotEmpty &&
        (_cache.length >= _maxCacheSize ||
            _cacheBytes + incoming > _maxCacheBytes)) {
      final evicted = _cache.remove(_cache.keys.first);
      if (evicted != null) {
        _cacheBytes -= _payloadSizeBytes(evicted);
      }
    }

    _cache[id] = payload;
    _cacheBytes += incoming;
  }

  static DecodedPayload _decodeInIsolate({
    required String name,
    required String path,
  }) {
    var file = File(path);
    if (!file.existsSync()) {
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

      if (lower.endsWith('.mp3') ||
          lower.endsWith('.wav') ||
          lower.endsWith('.ogg') ||
          lower.endsWith('.flac') ||
          lower.endsWith('.aac')) {
        return DecodedPayload(
          type: PayloadType.audio,
          name: name,
          path: path,
          bytes: bytes,
          textPreview: '${bytes.length} bytes',
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

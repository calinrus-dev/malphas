import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../core/models/flat_models.dart';
import '../../core/services/payload_decode_service.dart';
import '../../core/state/entity_store.dart';

class PayloadGridScreen extends StatefulWidget {
  const PayloadGridScreen({super.key});

  @override
  State<PayloadGridScreen> createState() => _PayloadGridScreenState();
}

class _PayloadGridScreenState extends State<PayloadGridScreen> {
  final EntityStore _store = EntityStore();
  final PayloadDecodeService _decoder = const PayloadDecodeService();
  final Map<int, ui.Image> _imageCache = {};

  @override
  void dispose() {
    for (final image in _imageCache.values) {
      image.dispose();
    }
    _imageCache.clear();
    super.dispose();
  }

  List<int> get _payloadIds => _store.payloads
      .asMap()
      .entries
      .where((e) => e.value != null)
      .map((e) => e.key)
      .toList();

  Future<ui.Image?> _decodeImage(EntityPayload payload) async {
    if (_imageCache.containsKey(payload.id)) return _imageCache[payload.id];
    final decoded = await _decoder.decodePayload(payload);
    if (decoded.type != PayloadType.image || decoded.bytes == null) {
      return null;
    }
    final codec = await ui.instantiateImageCodec(decoded.bytes!);
    final frame = await codec.getNextFrame();
    _imageCache[payload.id] = frame.image;
    return frame.image;
  }

  void _showPayloadMenu(BuildContext context, EntityPayload payload) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xff0d0d0d),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit, color: Colors.white60),
                title: const Text('Replace',
                    style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context),
              ),
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Colors.redAccent),
                title:
                    const Text('Delete', style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context),
              ),
              ListTile(
                leading: const Icon(Icons.star_outline, color: Colors.white60),
                title: const Text('Add to Favorites',
                    style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context),
              ),
              ListTile(
                leading: const Icon(Icons.copy, color: Colors.white60),
                title: const Text('Copy ID',
                    style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff050505),
      appBar: AppBar(
        backgroundColor: const Color(0xff0d0d0d),
        title: const Text('PAYLOADS',
            style: TextStyle(
                fontFamily: 'Courier',
                fontSize: 12,
                fontWeight: FontWeight.bold)),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 120,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.85,
        ),
        itemCount: _payloadIds.length,
        itemBuilder: (context, index) {
          final payloadId = _payloadIds[index];
          final payload = _store.getPayload(payloadId);
          if (payload == null) return const SizedBox.shrink();

          return GestureDetector(
            onLongPress: () => _showPayloadMenu(context, payload),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xff0d0d0d),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xff161616)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(16)),
                      child: _buildPreview(payload),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      payload.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Arial',
                        color: Colors.white70,
                        fontSize: 9,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPreview(EntityPayload payload) {
    final lower = payload.assetPath.toLowerCase();

    if (_isImage(lower)) {
      return FutureBuilder<ui.Image?>(
        future: _decodeImage(payload),
        builder: (context, snapshot) {
          final image = snapshot.data;
          if (image == null) {
            return const Center(
              child: CircularProgressIndicator(
                color: Colors.white24,
                strokeWidth: 2,
              ),
            );
          }
          return RawImage(
            image: image,
            fit: BoxFit.cover,
          );
        },
      );
    }

    if (_isAudio(lower)) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.audiotrack, color: Colors.white24, size: 28),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            height: 12,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: const Color(0xff161616),
              borderRadius: BorderRadius.circular(4),
            ),
            child: CustomPaint(
              painter: _WaveformPlaceholderPainter(),
            ),
          ),
        ],
      );
    }

    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.insert_drive_file, color: Colors.white24, size: 28),
        SizedBox(height: 6),
        Text(
          'Raw Binary',
          style: TextStyle(
            fontFamily: 'Courier',
            color: Colors.white38,
            fontSize: 8,
          ),
        ),
      ],
    );
  }

  bool _isImage(String lower) {
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  bool _isAudio(String lower) {
    return lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.aac');
  }
}

class _WaveformPlaceholderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xff00ffcc)
      ..strokeWidth = 1.5;
    const count = 12;
    final step = size.width / count;
    for (int i = 0; i < count; i++) {
      final h = size.height * (0.3 + (i % 3) * 0.25);
      final x = i * step + step / 2;
      canvas.drawLine(
        Offset(x, (size.height - h) / 2),
        Offset(x, (size.height + h) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

import 'dart:ffi' as dffi;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart' as ffi;
import 'types.dart';

class MalphasBindings extends ChangeNotifier {
  static const int maxCommandBufferCapacity = 2048;
  static const int _arenaSize = 8 * 1024 * 1024; // 8 MB

  static final MalphasBindings _instance = MalphasBindings._internal();
  factory MalphasBindings() => _instance;

  late final dffi.DynamicLibrary _nativeLib;
  late final int Function(dffi.Pointer<MalphasDoubleBufferBridge>, dffi.Pointer<dffi.Void>, int) initEngine;
  late final int Function(int, double, double) processInputEvent;
  late final int Function(int) processEngineTick;
  late final int Function(dffi.Pointer<ffi.Utf8>) loadResourcePack;
  late final int Function(dffi.Pointer<ffi.Utf8>, dffi.Pointer<ffi.Utf8>) _verifyBinaryIntegrity;
  late final int Function(dffi.Pointer<ffi.Utf8>, dffi.Pointer<ffi.Utf8>) _extractZipPackage;

  dffi.Pointer<MalphasDoubleBufferBridge>? _doubleBufferBridge = dffi.nullptr;
  dffi.Pointer<CoreCommandBuffer>? _bufferAPtr = dffi.nullptr;
  dffi.Pointer<CoreCommandBuffer>? _bufferBPtr = dffi.nullptr;
  dffi.Pointer<dffi.Void>? _arena = dffi.nullptr;

  bool isNativeAvailable = false;
  SnapshotCommandBuffer? _simulatedBuffer;

  MalphasBindings._internal() {
    _initializeBridge();
  }

  void _initializeBridge() {
    try {
      if (Platform.isAndroid) {
        _nativeLib = dffi.DynamicLibrary.open('libmalphas_core.so');
      } else if (Platform.isWindows) {
        _nativeLib = dffi.DynamicLibrary.open('malphas_core.dll');
      } else {
        _nativeLib = dffi.DynamicLibrary.open('libmalphas_core.so');
      }

      initEngine = _nativeLib.lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Pointer<MalphasDoubleBufferBridge>, dffi.Pointer<dffi.Void>, dffi.Uint32)>>('init_engine').asFunction();
      processInputEvent = _nativeLib.lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Int32, dffi.Float, dffi.Float)>>('process_input_event').asFunction();
      processEngineTick = _nativeLib.lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Uint64)>>('process_engine_tick').asFunction();
      loadResourcePack = _nativeLib.lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Pointer<ffi.Utf8>)>>('load_resource_pack').asFunction();
      _verifyBinaryIntegrity = _nativeLib.lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Pointer<ffi.Utf8>, dffi.Pointer<ffi.Utf8>)>>('verify_binary_integrity').asFunction();
      _extractZipPackage = _nativeLib.lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Pointer<ffi.Utf8>, dffi.Pointer<ffi.Utf8>)>>('extract_zip_package').asFunction();

      _initializeSharedMemory();
      isNativeAvailable = true;
    } catch (e, stack) {
      isNativeAvailable = false;
      _simulatedBuffer = SnapshotCommandBuffer();
      debugPrint('Error initializing Malphas native FFI bridge: $e\n$stack');
    }
  }

  void _initializeSharedMemory() {
    _doubleBufferBridge = ffi.calloc<MalphasDoubleBufferBridge>();
    
    // bufferA at offset 0, bufferB at offset 16 (CoreCommandBuffer is 16 bytes: 4 count + 4 pad + 8 pointer)
    _bufferAPtr = dffi.Pointer<CoreCommandBuffer>.fromAddress(_doubleBufferBridge!.address);
    _bufferBPtr = dffi.Pointer<CoreCommandBuffer>.fromAddress(_doubleBufferBridge!.address + 16);

    final commandsA = ffi.calloc<DartRenderCommand>(maxCommandBufferCapacity);
    final commandsB = ffi.calloc<DartRenderCommand>(maxCommandBufferCapacity);

    _bufferAPtr!.ref.commandCount = 0;
    _bufferAPtr!.ref.commands = commandsA;

    _bufferBPtr!.ref.commandCount = 0;
    _bufferBPtr!.ref.commands = commandsB;

    _doubleBufferBridge!.ref.atomicBackIndex = 0;

    _arena = ffi.calloc<dffi.Uint8>(_arenaSize).cast<dffi.Void>();

    initEngine(_doubleBufferBridge!, _arena!, _arenaSize);
  }

  dffi.Pointer<CoreCommandBuffer>? get commandBuffer {
    if (!isNativeAvailable) {
      return _simulatedBuffer?.buffer ?? dffi.nullptr;
    }
    if (_doubleBufferBridge == null || _doubleBufferBridge == dffi.nullptr) return dffi.nullptr;
    final backIndex = _doubleBufferBridge!.ref.atomicBackIndex;
    return (backIndex == 0) ? _bufferBPtr : _bufferAPtr;
  }

  dffi.Pointer<dffi.Void> get arena => _arena ?? dffi.nullptr;
  SnapshotCommandBuffer? get simulatedBuffer => _simulatedBuffer;

  ui.Image? fontAtlasImage;

  void checkAndLoadFontAtlas() {
    if (!isNativeAvailable || _arena == null || _arena == dffi.nullptr) return;

    final arenaUint32 = _arena!.cast<dffi.Uint32>();
    final packSize = arenaUint32[2];
    if (packSize == 0) {
      fontAtlasImage = null;
      return;
    }

    final atlasOffset = arenaUint32[6];

    const int atlasWidth = 512;
    const int atlasHeight = 512;

    final rawA8 = _arena!.cast<dffi.Uint8>() + atlasOffset;
    final Uint8List rgbaBytes = Uint8List(atlasWidth * atlasHeight * 4);

    for (int i = 0; i < atlasWidth * atlasHeight; i++) {
      final alpha = rawA8[i];
      rgbaBytes[i * 4] = 255;
      rgbaBytes[i * 4 + 1] = 255;
      rgbaBytes[i * 4 + 2] = 255;
      rgbaBytes[i * 4 + 3] = alpha;
    }

    ui.decodeImageFromPixels(
      rgbaBytes,
      atlasWidth,
      atlasHeight,
      ui.PixelFormat.rgba8888,
      (ui.Image img) {
        fontAtlasImage = img;
        notifyListeners();
      },
    );
  }

  int tick() {
    int count = 0;
    if (!isNativeAvailable) {
      if (_simulatedBuffer != null) {
        _simulatedBuffer!.executeSimulation();
        count = _simulatedBuffer!.buffer!.ref.commandCount;
      }
    } else {
      processEngineTick(0);
      final backIndex = _doubleBufferBridge!.ref.atomicBackIndex;
      final frontBuffer = (backIndex == 0) ? _bufferBPtr!.ref : _bufferAPtr!.ref;
      count = frontBuffer.commandCount;
    }
    notifyListeners();
    return count;
  }

  int loadPack(String path) {
    if (!isNativeAvailable) return -1;
    final pathPtr = path.toNativeUtf8();
    try {
      final res = loadResourcePack(pathPtr);
      if (res == 0) {
        checkAndLoadFontAtlas();
      }
      return res;
    } finally {
      ffi.calloc.free(pathPtr);
    }
  }

  int verifyBinary(String filepath, String expectedSha) {
    if (!isNativeAvailable) return 0;
    final fPtr = filepath.toNativeUtf8();
    final sPtr = expectedSha.toNativeUtf8();
    try {
      return _verifyBinaryIntegrity(fPtr, sPtr);
    } finally {
      ffi.calloc.free(fPtr);
      ffi.calloc.free(sPtr);
    }
  }

  int extractZip(String zipPath, String outputDir) {
    if (!isNativeAvailable) return 0;
    final zPtr = zipPath.toNativeUtf8();
    final oPtr = outputDir.toNativeUtf8();
    try {
      return _extractZipPackage(zPtr, oPtr);
    } finally {
      ffi.calloc.free(zPtr);
      ffi.calloc.free(oPtr);
    }
  }

  @override
  void dispose() {
    if (_doubleBufferBridge != null && _doubleBufferBridge != dffi.nullptr) {
      if (_bufferAPtr != null && _bufferAPtr != dffi.nullptr && _bufferAPtr!.ref.commands != dffi.nullptr) {
        ffi.calloc.free(_bufferAPtr!.ref.commands.cast());
      }
      if (_bufferBPtr != null && _bufferBPtr != dffi.nullptr && _bufferBPtr!.ref.commands != dffi.nullptr) {
        ffi.calloc.free(_bufferBPtr!.ref.commands.cast());
      }
      ffi.calloc.free(_doubleBufferBridge!.cast());
    }
    if (_arena != null && _arena != dffi.nullptr) {
      ffi.calloc.free(_arena!.cast());
    }
    super.dispose();
  }
}

class SnapshotCommandBuffer {
  dffi.Pointer<CoreCommandBuffer>? buffer;

  SnapshotCommandBuffer() {
    buffer = ffi.calloc<CoreCommandBuffer>();
    buffer!.ref.commandCount = 0;
    buffer!.ref.commands = ffi.calloc<DartRenderCommand>(2);
  }

  void executeSimulation() {
    buffer!.ref.commandCount = 1;
    buffer!.ref.commands[0].commandType = 1;
    buffer!.ref.commands[0].x = 250;
    buffer!.ref.commands[0].y = 250;
    buffer!.ref.commands[0].width = 500;
    buffer!.ref.commands[0].height = 500;
    buffer!.ref.commands[0].colorRgba = 0xFF1A1B1C;
  }
}

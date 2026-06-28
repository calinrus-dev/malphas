import 'dart:ffi' as dffi;
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart' as ffi;
import 'types.dart';

/// Immutable snapshot of the native engine telemetry counters.
///
/// All durations are in microseconds.  A zero value means either that the
/// metric has not yet been sampled (e.g. the engine has not ticked) or that
/// the counter is legitimately zero.
class TelemetrySnapshot {
  final int vmTickMicros;
  final int pulseLatencyMicros;
  final int hitTestsCount;
  final int commandsGeneratedCount;

  const TelemetrySnapshot({
    required this.vmTickMicros,
    required this.pulseLatencyMicros,
    required this.hitTestsCount,
    required this.commandsGeneratedCount,
  });

  @override
  String toString() {
    return 'TelemetrySnapshot(vmTickMicros: $vmTickMicros, '
        'pulseLatencyMicros: $pulseLatencyMicros, '
        'hitTestsCount: $hitTestsCount, '
        'commandsGeneratedCount: $commandsGeneratedCount)';
  }
}

/// Singleton FFI gateway to the Rust `malphas_core` cdylib.
///
/// Design rules enforced here:
/// * All shared-memory buffers (bridge, command arrays, arena) are allocated
///   through the Rust-aligned allocator (`malphas_alloc` / `malphas_free`)
///   with 16-byte alignment; `ffi.calloc` is never used for shared memory.
/// * Dart never performs pointer arithmetic on `MalphasDoubleBufferBridge` or
///   copies nested structs by value.  All buffer pointers come from Rust
///   getters (`get_buffer_a_ptr`, `get_buffer_b_ptr`, etc.).
/// * Input events are pushed to a Rust MPSC-style Mutex queue; Dart never
///   writes directly into the Arena for events.
class MalphasBindings extends ChangeNotifier {
  static const int maxCommandBufferCapacity = 2048;
  static const int _arenaSize = 8 * 1024 * 1024; // 8 MB

  static final MalphasBindings _instance = MalphasBindings._internal();
  factory MalphasBindings() => _instance;

  late dffi.DynamicLibrary _nativeLib;

  late final int Function(dffi.Pointer<MalphasDoubleBufferBridge>, dffi.Pointer<dffi.Void>, int, int) initEngine;
  late final int Function() shutdownEngine;
  late final int Function(int, double, double) processInputEvent;
  late final int Function() triggerEnginePulse;
  late final int Function(int) processEngineTick;
  late final int Function(dffi.Pointer<ffi.Utf8>) loadResourcePack;
  late final dffi.Pointer<dffi.Uint8> Function(int) malphasAlloc;
  late final void Function(dffi.Pointer<dffi.Uint8>, int) malphasFree;
  late final int Function(dffi.Pointer<dffi.Uint8>, int) loadResourcePackRaw;
  late final int Function(dffi.Pointer<ffi.Utf8>, dffi.Pointer<ffi.Utf8>) verifyBinaryIntegrity;
  late final int Function(dffi.Pointer<ffi.Utf8>, dffi.Pointer<ffi.Utf8>, dffi.Pointer<ffi.Utf8>)
      verifyEngineSignature;
  late final int Function(dffi.Pointer<ffi.Utf8>, dffi.Pointer<ffi.Utf8>) extractZipPackage;
  late final int Function(int) _pauseEngine;

  // Portable pointer delegates exposed from Rust.
  late final dffi.Pointer<CoreCommandBuffer> Function(dffi.Pointer<MalphasDoubleBufferBridge>) getBufferAPtr;
  late final dffi.Pointer<CoreCommandBuffer> Function(dffi.Pointer<MalphasDoubleBufferBridge>) getBufferBPtr;
  late final int Function(dffi.Pointer<MalphasDoubleBufferBridge>) getBackIndex;
  late final int Function(dffi.Pointer<CoreCommandBuffer>) getCommandCount;
  late final dffi.Pointer<DartRenderCommand> Function(dffi.Pointer<CoreCommandBuffer>) getCommandsPointer;
  late final int Function(dffi.Pointer<MalphasDoubleBufferBridge>) getCommandsWritten;

  // Telemetry getters for MALPHAS REINFORCED v2.2 Phase 5.
  late final int Function() getVmTickMicros;
  late final int Function() getPulseLatencyMicros;
  late final int Function() getHitTestsCount;
  late final int Function() getCommandsGeneratedCount;

  // Safe Arena setup helpers (Rust holds the write lock).
  late final int Function(int) setEntitiesCount;
  late final int Function(int, dffi.Pointer<dffi.Uint8>, int) writeArenaBytes;
  late final int Function(
    int entityId,
    int commandType,
    int layer,
    double x,
    double y,
    double width,
    double height,
    int colorRgba,
    double speedX,
    double speedY,
    double minX,
    double maxX,
    double minY,
    double maxY,
    int strOffset,
  ) setEntity;

  dffi.Pointer<MalphasDoubleBufferBridge>? _doubleBufferBridge = dffi.nullptr;
  dffi.Pointer<CoreCommandBuffer>? _bufferAPtr = dffi.nullptr;
  dffi.Pointer<CoreCommandBuffer>? _bufferBPtr = dffi.nullptr;
  dffi.Pointer<dffi.Void>? _arena = dffi.nullptr;

  bool isNativeAvailable = false;
  SnapshotCommandBuffer? _simulatedBuffer;

  ui.Image? fontAtlasImage;

  static void cleanupTempLibraries() {
    try {
      final workspace = Directory.current.path;
      final motorsDir = Directory('$workspace/motors');
      if (motorsDir.existsSync()) {
        for (final file in motorsDir.listSync()) {
          if (file is File) {
            final name = file.uri.pathSegments.last;
            if (name.startsWith('malphas_core_temp_') &&
                (name.endsWith('.dll') || name.endsWith('.so') || name.endsWith('.dylib'))) {
              try {
                file.deleteSync();
              } catch (_) {
                // File is locked by the running process; skip it.
              }
            }
          }
        }
      }
    } catch (_) {
      // Silent catch.
    }
  }

  MalphasBindings._internal() {
    _initializeBridge();
  }

  void _initializeBridge() {
    try {
      _nativeLib = _openNativeLibrary(null);
      _bindAllFunctions();
      _initializeSharedMemory();
      isNativeAvailable = true;
    } catch (e, stack) {
      isNativeAvailable = false;
      _simulatedBuffer = SnapshotCommandBuffer();
      debugPrint('Error initializing Malphas native FFI bridge: $e\n$stack');
    }
  }

  dffi.DynamicLibrary _openNativeLibrary(String? explicitSourcePath) {
    final workspace = Directory.current.path;
    final motorsDir = Directory('$workspace/motors');
    if (!motorsDir.existsSync()) {
      motorsDir.createSync(recursive: true);
    }

    cleanupTempLibraries();

    String originalName;
    String ext;
    if (Platform.isWindows) {
      originalName = 'malphas_core.dll';
      ext = '.dll';
    } else if (Platform.isMacOS) {
      originalName = 'libmalphas_core.dylib';
      ext = '.dylib';
    } else {
      originalName = 'libmalphas_core.so';
      ext = '.so';
    }

    File originalFile;
    if (explicitSourcePath != null) {
      originalFile = File(explicitSourcePath);
      if (!originalFile.existsSync()) {
        throw Exception('Explicit native library not found: $explicitSourcePath');
      }
    } else {
      originalFile = File('$workspace/$originalName');
      if (!originalFile.existsSync()) {
        originalFile = File('$workspace/malphas_core/target/release/$originalName');
      }
      if (!originalFile.existsSync()) {
        // Let DynamicLibrary.open try the platform search path.
        return dffi.DynamicLibrary.open(originalName);
      }
    }

    final tempPath =
        '${motorsDir.path}/malphas_core_temp_${DateTime.now().millisecondsSinceEpoch}$ext';
    originalFile.copySync(tempPath);
    return dffi.DynamicLibrary.open(tempPath);
  }

  void _bindAllFunctions() {
    initEngine = _nativeLib
        .lookup<dffi.NativeFunction<
            dffi.Int32 Function(dffi.Pointer<MalphasDoubleBufferBridge>, dffi.Pointer<dffi.Void>,
                dffi.Uint32, dffi.Uint32)>>('init_engine')
        .asFunction();
    shutdownEngine = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function()>>('shutdown_engine')
        .asFunction();
    _pauseEngine = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Int32)>>('pause_engine')
        .asFunction();
    processInputEvent = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Int32, dffi.Float, dffi.Float)>>
            ('process_input_event')
        .asFunction();
    triggerEnginePulse = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function()>>('trigger_engine_pulse')
        .asFunction();
    processEngineTick = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Uint64)>>('process_engine_tick')
        .asFunction();
    loadResourcePack = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Pointer<ffi.Utf8>)>>
            ('load_resource_pack')
        .asFunction();
    malphasAlloc = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Pointer<dffi.Uint8> Function(dffi.IntPtr)>>
            ('malphas_alloc')
        .asFunction();
    malphasFree = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Void Function(dffi.Pointer<dffi.Uint8>, dffi.IntPtr)>>
            ('malphas_free')
        .asFunction();
    loadResourcePackRaw = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Pointer<dffi.Uint8>, dffi.Uint32)>>
            ('load_resource_pack_raw')
        .asFunction();
    verifyBinaryIntegrity = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Pointer<ffi.Utf8>, dffi.Pointer<ffi.Utf8>)>>
            ('verify_binary_integrity')
        .asFunction();
    verifyEngineSignature = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Int32 Function(dffi.Pointer<ffi.Utf8>, dffi.Pointer<ffi.Utf8>,
                    dffi.Pointer<ffi.Utf8>)>>('verify_engine_signature')
        .asFunction();
    extractZipPackage = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Pointer<ffi.Utf8>, dffi.Pointer<ffi.Utf8>)>>
            ('extract_zip_package')
        .asFunction();

    getBufferAPtr = _nativeLib
        .lookup<dffi.NativeFunction<
            dffi.Pointer<CoreCommandBuffer> Function(dffi.Pointer<MalphasDoubleBufferBridge>)>>
            ('get_buffer_a_ptr')
        .asFunction();
    getBufferBPtr = _nativeLib
        .lookup<dffi.NativeFunction<
            dffi.Pointer<CoreCommandBuffer> Function(dffi.Pointer<MalphasDoubleBufferBridge>)>>
            ('get_buffer_b_ptr')
        .asFunction();
    getBackIndex = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Uint8 Function(dffi.Pointer<MalphasDoubleBufferBridge>)>>
            ('get_back_index')
        .asFunction();
    getCommandCount = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Uint32 Function(dffi.Pointer<CoreCommandBuffer>)>>
            ('get_command_count')
        .asFunction();
    getCommandsPointer = _nativeLib
        .lookup<dffi.NativeFunction<
            dffi.Pointer<DartRenderCommand> Function(dffi.Pointer<CoreCommandBuffer>)>>
            ('get_commands_pointer')
        .asFunction();
    getCommandsWritten = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Uint32 Function(dffi.Pointer<MalphasDoubleBufferBridge>)>>
            ('get_commands_written')
        .asFunction();

    getVmTickMicros = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Uint64 Function()>>('get_vm_tick_micros')
        .asFunction();
    getPulseLatencyMicros = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Uint64 Function()>>('get_pulse_latency_micros')
        .asFunction();
    getHitTestsCount = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Uint64 Function()>>('get_hit_tests_count')
        .asFunction();
    getCommandsGeneratedCount = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Uint64 Function()>>('get_commands_generated_count')
        .asFunction();

    setEntitiesCount = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Uint32)>>('set_entities_count')
        .asFunction();
    writeArenaBytes = _nativeLib
        .lookup<dffi.NativeFunction<
            dffi.Int32 Function(dffi.Uint32, dffi.Pointer<dffi.Uint8>, dffi.Uint32)>>
            ('write_arena_bytes')
        .asFunction();
    setEntity = _nativeLib
        .lookup<dffi.NativeFunction<
            dffi.Int32 Function(
              dffi.Uint32, // entity_id
              dffi.Uint8,  // command_type
              dffi.Uint8,  // layer
              dffi.Float,  // x
              dffi.Float,  // y
              dffi.Float,  // width
              dffi.Float,  // height
              dffi.Uint32, // color_rgba
              dffi.Float,  // speed_x
              dffi.Float,  // speed_y
              dffi.Float,  // min_x
              dffi.Float,  // max_x
              dffi.Float,  // min_y
              dffi.Float,  // max_y
              dffi.Uint32, // str_offset
            )>>('set_entity')
        .asFunction();
  }

  void _initializeSharedMemory() {
    // Allocate the bridge and command arrays through the Rust allocator so we
    // are guaranteed 16-byte alignment on all architectures.
    final bridgeSize = dffi.sizeOf<MalphasDoubleBufferBridge>();
    _doubleBufferBridge = malphasAlloc(bridgeSize).cast<MalphasDoubleBufferBridge>();
    if (_doubleBufferBridge == dffi.nullptr) {
      throw Exception('Failed to allocate double-buffer bridge');
    }

    final commandBufferSize = maxCommandBufferCapacity * dffi.sizeOf<DartRenderCommand>();
    final commandsA = malphasAlloc(commandBufferSize).cast<DartRenderCommand>();
    final commandsB = malphasAlloc(commandBufferSize).cast<DartRenderCommand>();
    if (commandsA == dffi.nullptr || commandsB == dffi.nullptr) {
      throw Exception('Failed to allocate command buffers');
    }

    _bufferAPtr = getBufferAPtr(_doubleBufferBridge!);
    _bufferBPtr = getBufferBPtr(_doubleBufferBridge!);

    _doubleBufferBridge!.ref.atomicBackIndex = 0;
    _doubleBufferBridge!.ref.commandsWritten = 0;

    _bufferAPtr!.ref.commandCount = 0;
    _bufferAPtr!.ref.commands = commandsA;

    _bufferBPtr!.ref.commandCount = 0;
    _bufferBPtr!.ref.commands = commandsB;

    _arena = malphasAlloc(_arenaSize).cast<dffi.Void>();
    if (_arena == dffi.nullptr) {
      throw Exception('Failed to allocate arena');
    }

    initEngine(_doubleBufferBridge!, _arena!, _arenaSize, maxCommandBufferCapacity);
  }

  /// Hot-swaps the native library by path.  This shuts the engine down,
  /// releases shared-memory handles, deletes any unlocked temp binaries, copies
  /// the requested binary to a unique filename (bypassing the Dart/Windows DLL
  /// cache), rebinds every FFI function, and reinitialises shared memory.
  void reloadNativeLibrary(String sourcePath) {
    shutdownEngine();
    _freeSharedMemory();
    cleanupTempLibraries();

    _nativeLib = _openNativeLibrary(sourcePath);
    _bindAllFunctions();
    _initializeSharedMemory();
  }

  /// Returns the buffer that Flutter should read from (the *front* buffer).
  /// The Rust engine writes into the back buffer selected by `atomicBackIndex`;
  /// the opposite buffer is therefore immutable for the duration of this frame.
  dffi.Pointer<CoreCommandBuffer>? get commandBuffer {
    if (!isNativeAvailable) {
      return _simulatedBuffer?.buffer ?? dffi.nullptr;
    }
    if (_doubleBufferBridge == null || _doubleBufferBridge == dffi.nullptr) {
      return dffi.nullptr;
    }
    final backIndex = getBackIndex(_doubleBufferBridge!);
    return (backIndex == 0) ? _bufferBPtr : _bufferAPtr;
  }

  dffi.Pointer<dffi.Void> get arena => _arena ?? dffi.nullptr;
  SnapshotCommandBuffer? get simulatedBuffer => _simulatedBuffer;

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

  /// Reads the current telemetry counters from the native engine.
  ///
  /// Returns a zero-filled snapshot when the native library is unavailable,
  /// so callers can safely call this every frame without branching.
  TelemetrySnapshot readTelemetry() {
    if (!isNativeAvailable) {
      return const TelemetrySnapshot(
        vmTickMicros: 0,
        pulseLatencyMicros: 0,
        hitTestsCount: 0,
        commandsGeneratedCount: 0,
      );
    }
    return TelemetrySnapshot(
      vmTickMicros: getVmTickMicros(),
      pulseLatencyMicros: getPulseLatencyMicros(),
      hitTestsCount: getHitTestsCount(),
      commandsGeneratedCount: getCommandsGeneratedCount(),
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
      // Single-clock sync: Flutter's Ticker is the only clock source.  Wake
      // the Rust simulation thread once per vsync; it will process the tick
      // asynchronously on its own core while we read the latest front buffer.
      triggerEnginePulse();
      final backIndex = getBackIndex(_doubleBufferBridge!);
      final frontBuffer = (backIndex == 0) ? _bufferBPtr! : _bufferAPtr!;
      count = getCommandCount(frontBuffer);
    }
    notifyListeners();
    return count;
  }

  int loadPack(String path) {
    if (!isNativeAvailable) return -1;
    final file = File(path);
    if (!file.existsSync()) return -2;

    final bytes = file.readAsBytesSync();
    final size = bytes.length;

    final ptr = malphasAlloc(size);
    if (ptr == dffi.nullptr) return -3;

    try {
      ptr.asTypedList(size).setAll(0, bytes);
      final res = loadResourcePackRaw(ptr, size);
      if (res == 0) {
        checkAndLoadFontAtlas();
      }
      return res;
    } finally {
      malphasFree(ptr, size);
    }
  }

  int verifyBinary(String filepath, String expectedSha) {
    if (!isNativeAvailable) return 0;
    final fPtr = filepath.toNativeUtf8();
    final sPtr = expectedSha.toNativeUtf8();
    try {
      return verifyBinaryIntegrity(fPtr, sPtr);
    } finally {
      ffi.calloc.free(fPtr);
      ffi.calloc.free(sPtr);
    }
  }

  int verifyEngine(String filepath, String signatureHex, String publicKeyHex) {
    if (!isNativeAvailable) return 0;
    final fPtr = filepath.toNativeUtf8();
    final sPtr = signatureHex.toNativeUtf8();
    final pPtr = publicKeyHex.toNativeUtf8();
    try {
      return verifyEngineSignature(fPtr, sPtr, pPtr);
    } finally {
      ffi.calloc.free(fPtr);
      ffi.calloc.free(sPtr);
      ffi.calloc.free(pPtr);
    }
  }

  int extractZip(String zipPath, String outputDir) {
    if (!isNativeAvailable) return 0;
    final zPtr = zipPath.toNativeUtf8();
    final oPtr = outputDir.toNativeUtf8();
    try {
      return extractZipPackage(zPtr, oPtr);
    } finally {
      ffi.calloc.free(zPtr);
      ffi.calloc.free(oPtr);
    }
  }

  int pauseEngine(bool paused) => _pauseEngine(paused ? 1 : 0);

  /// Safe entity initialisation.  Rust holds the Arena write lock for the
  /// duration of the call, so it cannot race the simulation tick.
  int configureEntity({
    required int entityId,
    required int commandType,
    required int layer,
    required double x,
    required double y,
    required double width,
    required double height,
    required int colorRgba,
    required double speedX,
    required double speedY,
    required double minX,
    required double maxX,
    required double minY,
    required double maxY,
    int strOffset = 0,
  }) {
    return setEntity(
      entityId,
      commandType,
      layer,
      x,
      y,
      width,
      height,
      colorRgba,
      speedX,
      speedY,
      minX,
      maxX,
      minY,
      maxY,
      strOffset,
    );
  }

  /// Safe Arena byte write.  The engine must be paused while performing
  /// multi-write setup to avoid torn state.
  int writeArenaString(int offset, Uint8List bytes) {
    if (!isNativeAvailable) return -1;
    final ptr = ffi.calloc<dffi.Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return writeArenaBytes(offset, ptr, bytes.length);
    } finally {
      ffi.calloc.free(ptr);
    }
  }

  /// Writes a [TextPayload] header followed by the string bytes into the Arena.
  /// The written offset is the pointer passed to `setEntity` as `strOffset`.
  int writeArenaText(
    int offset,
    double x,
    double y,
    double fontSize,
    Uint8List bytes,
  ) {
    if (!isNativeAvailable) return -1;
    final payloadSize = dffi.sizeOf<TextPayload>();
    final totalSize = payloadSize + bytes.length;
    final ptr = ffi.calloc<dffi.Uint8>(totalSize);
    try {
      final payload = ptr.cast<TextPayload>().ref;
      payload.x = x;
      payload.y = y;
      payload.fontSize = fontSize;
      final stringPtr = ptr + payloadSize;
      stringPtr.asTypedList(bytes.length).setAll(0, bytes);
      return writeArenaBytes(offset, ptr, totalSize);
    } finally {
      ffi.calloc.free(ptr);
    }
  }

  /// Frees every shared-memory buffer through the Rust allocator.  Must only
  /// be called after `shutdownEngine()` has returned and the simulation thread
  /// has exited, otherwise the engine could dereference freed memory.
  void _freeSharedMemory() {
    if (_doubleBufferBridge != null && _doubleBufferBridge != dffi.nullptr) {
      if (_bufferAPtr != null && _bufferAPtr != dffi.nullptr) {
        final commandsA = getCommandsPointer(_bufferAPtr!);
        if (commandsA != dffi.nullptr) {
          malphasFree(
            commandsA.cast(),
            maxCommandBufferCapacity * dffi.sizeOf<DartRenderCommand>(),
          );
        }
      }
      if (_bufferBPtr != null && _bufferBPtr != dffi.nullptr) {
        final commandsB = getCommandsPointer(_bufferBPtr!);
        if (commandsB != dffi.nullptr) {
          malphasFree(
            commandsB.cast(),
            maxCommandBufferCapacity * dffi.sizeOf<DartRenderCommand>(),
          );
        }
      }
      malphasFree(_doubleBufferBridge!.cast(), dffi.sizeOf<MalphasDoubleBufferBridge>());
    }
    if (_arena != null && _arena != dffi.nullptr) {
      malphasFree(_arena!.cast<dffi.Uint8>(), _arenaSize);
    }
    _doubleBufferBridge = dffi.nullptr;
    _bufferAPtr = dffi.nullptr;
    _bufferBPtr = dffi.nullptr;
    _arena = dffi.nullptr;
  }

  @override
  void dispose() {
    if (isNativeAvailable) {
      try {
        shutdownEngine();
        _freeSharedMemory();
      } catch (e) {
        debugPrint('MalphasBindings.dispose error: $e');
      }
    }
    fontAtlasImage?.dispose();
    fontAtlasImage = null;
    super.dispose();
  }
}

/// Fallback command buffer used when the native library cannot be loaded.
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

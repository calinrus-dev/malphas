import 'dart:ffi' as dffi;
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart' as ffi;
import 'arena_layout.dart';
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
  static const int _arenaSize = 16 * 1024 * 1024; // 16 MB

  static MalphasBindings _instance = MalphasBindings._internal();
  factory MalphasBindings() => _instance;

  /// Resets the singleton to a fresh engine instance.
  ///
  /// This is intended for tests only. It shuts down the native engine, frees
  /// shared memory, and creates a new binding instance so each test starts from
  /// a clean state.
  static void reset() {
    _instance.dispose();
    _instance = MalphasBindings._internal();
  }

  late dffi.DynamicLibrary _nativeLib;

  late final int Function(
    dffi.Pointer<MalphasDoubleBufferBridge>,
    dffi.Pointer<dffi.Void>,
    int,
    int,
  ) initEngine;
  late final int Function() shutdownEngine;
  late final int Function(int, double, double) processInputEvent;
  late final int Function() triggerEnginePulse;
  late final int Function(int) processEngineTick;
  late final int Function(dffi.Pointer<ffi.Utf8>) loadResourcePack;
  late final dffi.Pointer<dffi.Uint8> Function(int) malphasAlloc;
  late final void Function(dffi.Pointer<dffi.Uint8>, int) malphasFree;
  late final int Function(dffi.Pointer<dffi.Uint8>, int) loadResourcePackRaw;
  late final int Function(dffi.Pointer<ffi.Utf8>, dffi.Pointer<ffi.Utf8>)
      verifyBinaryIntegrity;
  late final int Function(
    dffi.Pointer<ffi.Utf8>,
    dffi.Pointer<ffi.Utf8>,
    dffi.Pointer<ffi.Utf8>,
  ) verifyEngineSignature;
  late final int Function(dffi.Pointer<ffi.Utf8>, dffi.Pointer<ffi.Utf8>)
      extractZipPackage;
  late final int Function(int) _pauseEngine;

  // Portable pointer delegates exposed from Rust.
  late final dffi.Pointer<DartRenderCommand> Function(
    dffi.Pointer<MalphasDoubleBufferBridge>,
  ) getBufferACommands;
  late final dffi.Pointer<DartRenderCommand> Function(
    dffi.Pointer<MalphasDoubleBufferBridge>,
  ) getBufferBCommands;
  late final int Function(dffi.Pointer<MalphasDoubleBufferBridge>)
      getBufferACommandCount;
  late final int Function(dffi.Pointer<MalphasDoubleBufferBridge>)
      getBufferBCommandCount;
  late final int Function(dffi.Pointer<MalphasDoubleBufferBridge>) getBackIndex;
  late final int Function(dffi.Pointer<MalphasDoubleBufferBridge>)
      getCommandsWritten;
  late final dffi.Pointer<TextPayload> Function(dffi.Pointer<DartRenderCommand>)
      getTextPayloadPointer;

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
                (name.endsWith('.dll') ||
                    name.endsWith('.so') ||
                    name.endsWith('.dylib'))) {
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
        throw Exception(
          'Explicit native library not found: $explicitSourcePath',
        );
      }
    } else {
      originalFile = File('$workspace/$originalName');
      if (!originalFile.existsSync()) {
        originalFile = File(
          '$workspace/malphas_core/target/release/$originalName',
        );
      }
      if (!originalFile.existsSync()) {
        originalFile = File('$workspace/../$originalName');
      }
      if (!originalFile.existsSync()) {
        originalFile = File(
          '$workspace/../target/release/$originalName',
        );
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
        .lookup<
            dffi.NativeFunction<
                dffi.Int32 Function(
                  dffi.Pointer<MalphasDoubleBufferBridge>,
                  dffi.Pointer<dffi.Void>,
                  dffi.Uint32,
                  dffi.Uint32,
                )>>('init_engine')
        .asFunction();
    shutdownEngine = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function()>>('shutdown_engine')
        .asFunction();
    _pauseEngine = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Int32)>>(
          'pause_engine',
        )
        .asFunction();
    processInputEvent = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Int32 Function(
                    dffi.Int32, dffi.Float, dffi.Float)>>('process_input_event')
        .asFunction();
    triggerEnginePulse = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function()>>(
          'trigger_engine_pulse',
        )
        .asFunction();
    processEngineTick = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Uint64)>>(
          'process_engine_tick',
        )
        .asFunction();
    loadResourcePack = _nativeLib
        .lookup<
                dffi
                .NativeFunction<dffi.Int32 Function(dffi.Pointer<ffi.Utf8>)>>(
            'load_resource_pack')
        .asFunction();
    malphasAlloc = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Pointer<dffi.Uint8> Function(
                    dffi.IntPtr)>>('malphas_alloc')
        .asFunction();
    malphasFree = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Void Function(
                    dffi.Pointer<dffi.Uint8>, dffi.IntPtr)>>('malphas_free')
        .asFunction();
    loadResourcePackRaw = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Int32 Function(dffi.Pointer<dffi.Uint8>,
                    dffi.Uint32)>>('load_resource_pack_raw')
        .asFunction();
    verifyBinaryIntegrity = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Int32 Function(dffi.Pointer<ffi.Utf8>,
                    dffi.Pointer<ffi.Utf8>)>>('verify_binary_integrity')
        .asFunction();
    verifyEngineSignature = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Int32 Function(
                  dffi.Pointer<ffi.Utf8>,
                  dffi.Pointer<ffi.Utf8>,
                  dffi.Pointer<ffi.Utf8>,
                )>>('verify_engine_signature')
        .asFunction();
    extractZipPackage = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Int32 Function(dffi.Pointer<ffi.Utf8>,
                    dffi.Pointer<ffi.Utf8>)>>('extract_zip_package')
        .asFunction();

    getBufferACommands = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Pointer<DartRenderCommand> Function(
                  dffi.Pointer<MalphasDoubleBufferBridge>,
                )>>('get_buffer_a_commands')
        .asFunction();
    getBufferBCommands = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Pointer<DartRenderCommand> Function(
                  dffi.Pointer<MalphasDoubleBufferBridge>,
                )>>('get_buffer_b_commands')
        .asFunction();
    getBufferACommandCount = _nativeLib
        .lookup<
                dffi.NativeFunction<
                    dffi.Uint32 Function(
                        dffi.Pointer<MalphasDoubleBufferBridge>)>>(
            'get_buffer_a_command_count')
        .asFunction();
    getBufferBCommandCount = _nativeLib
        .lookup<
                dffi.NativeFunction<
                    dffi.Uint32 Function(
                        dffi.Pointer<MalphasDoubleBufferBridge>)>>(
            'get_buffer_b_command_count')
        .asFunction();
    getBackIndex = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Uint8 Function(
                    dffi.Pointer<MalphasDoubleBufferBridge>)>>('get_back_index')
        .asFunction();
    getCommandsWritten = _nativeLib
        .lookup<
                dffi.NativeFunction<
                    dffi.Uint32 Function(
                        dffi.Pointer<MalphasDoubleBufferBridge>)>>(
            'get_commands_written')
        .asFunction();
    getTextPayloadPointer = _nativeLib
        .lookup<
                dffi.NativeFunction<
                    dffi.Pointer<TextPayload> Function(
                        dffi.Pointer<DartRenderCommand>)>>(
            'get_text_payload_pointer')
        .asFunction();

    getVmTickMicros = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Uint64 Function()>>(
          'get_vm_tick_micros',
        )
        .asFunction();
    getPulseLatencyMicros = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Uint64 Function()>>(
          'get_pulse_latency_micros',
        )
        .asFunction();
    getHitTestsCount = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Uint64 Function()>>(
          'get_hit_tests_count',
        )
        .asFunction();
    getCommandsGeneratedCount = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Uint64 Function()>>(
          'get_commands_generated_count',
        )
        .asFunction();

    setEntitiesCount = _nativeLib
        .lookup<dffi.NativeFunction<dffi.Int32 Function(dffi.Uint32)>>(
          'set_entities_count',
        )
        .asFunction();
    writeArenaBytes = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Int32 Function(
                  dffi.Uint32,
                  dffi.Pointer<dffi.Uint8>,
                  dffi.Uint32,
                )>>('write_arena_bytes')
        .asFunction();
    setEntity = _nativeLib
        .lookup<
            dffi.NativeFunction<
                dffi.Int32 Function(
                  dffi.Uint32, // entity_id
                  dffi.Uint8, // command_type
                  dffi.Uint8, // layer
                  dffi.Float, // x
                  dffi.Float, // y
                  dffi.Float, // width
                  dffi.Float, // height
                  dffi.Uint32, // color_rgba
                  dffi.Float, // speed_x
                  dffi.Float, // speed_y
                  dffi.Float, // min_x
                  dffi.Float, // max_x
                  dffi.Float, // min_y
                  dffi.Float, // max_y
                  dffi.Uint32, // str_offset
                )>>('set_entity')
        .asFunction();
  }

  void _initializeSharedMemory() {
    // Allocate the bridge and command arrays through the Rust allocator so we
    // are guaranteed 16-byte alignment on all architectures.
    final bridgeSize = dffi.sizeOf<MalphasDoubleBufferBridge>();
    _doubleBufferBridge = malphasAlloc(
      bridgeSize,
    ).cast<MalphasDoubleBufferBridge>();
    if (_doubleBufferBridge == dffi.nullptr) {
      throw Exception('Failed to allocate double-buffer bridge');
    }

    final commandBufferSize =
        maxCommandBufferCapacity * dffi.sizeOf<DartRenderCommand>();
    final commandsA = malphasAlloc(commandBufferSize).cast<DartRenderCommand>();
    final commandsB = malphasAlloc(commandBufferSize).cast<DartRenderCommand>();
    if (commandsA == dffi.nullptr || commandsB == dffi.nullptr) {
      throw Exception('Failed to allocate command buffers');
    }

    _doubleBufferBridge!.ref.bufferACommandCount = 0;
    _doubleBufferBridge!.ref.bufferACommands = commandsA;

    _doubleBufferBridge!.ref.bufferBCommandCount = 0;
    _doubleBufferBridge!.ref.bufferBCommands = commandsB;

    _doubleBufferBridge!.ref.atomicBackIndex = 0;
    _doubleBufferBridge!.ref.commandsWritten = 0;

    _arena = malphasAlloc(_arenaSize).cast<dffi.Void>();
    if (_arena == dffi.nullptr) {
      throw Exception('Failed to allocate arena');
    }

    final initResult = initEngine(
      _doubleBufferBridge!,
      _arena!,
      _arenaSize,
      maxCommandBufferCapacity,
    );
    _checkFfiResult(initResult, 'init_engine');
  }

  void _checkFfiResult(int result, String operation) {
    if (result < 0) {
      throw Exception('FFI operation "$operation" failed with code $result');
    }
  }

  /// Hot-swaps the native library by path.  This shuts the engine down,
  /// releases shared-memory handles, deletes any unlocked temp binaries, copies
  /// the requested binary to a unique filename (bypassing the Dart/Windows DLL
  /// cache), rebinds every FFI function, and reinitialises shared memory.
  void reloadNativeLibrary(String sourcePath) {
    _checkFfiResult(shutdownEngine(), 'shutdown_engine');
    _freeSharedMemory();
    cleanupTempLibraries();

    _nativeLib = _openNativeLibrary(sourcePath);
    _bindAllFunctions();
    _initializeSharedMemory();
  }

  /// Returns the pointer to the command array of the front buffer.
  dffi.Pointer<DartRenderCommand> get commandsPointer {
    if (!isNativeAvailable) {
      return _simulatedBuffer?.commands ?? dffi.nullptr;
    }
    if (_doubleBufferBridge == null || _doubleBufferBridge == dffi.nullptr) {
      return dffi.nullptr;
    }
    final backIndex = getBackIndex(_doubleBufferBridge!);
    return (backIndex == 0)
        ? getBufferBCommands(_doubleBufferBridge!)
        : getBufferACommands(_doubleBufferBridge!);
  }

  /// Returns the number of commands written to the front buffer.
  int get commandCount {
    if (!isNativeAvailable) {
      return _simulatedBuffer?.commandCount ?? 0;
    }
    if (_doubleBufferBridge == null || _doubleBufferBridge == dffi.nullptr) {
      return 0;
    }
    final backIndex = getBackIndex(_doubleBufferBridge!);
    return (backIndex == 0)
        ? getBufferBCommandCount(_doubleBufferBridge!)
        : getBufferACommandCount(_doubleBufferBridge!);
  }

  dffi.Pointer<dffi.Void> get arena => _arena ?? dffi.nullptr;
  int get arenaSize => _arenaSize;
  SnapshotCommandBuffer? get simulatedBuffer => _simulatedBuffer;

  void checkAndLoadFontAtlas() {
    if (!isNativeAvailable || _arena == null || _arena == dffi.nullptr) return;

    final arenaUint32 = _arena!.cast<dffi.Uint32>();
    final packSize = arenaUint32[ArenaLayout.staticResourcesSize ~/ 4];
    if (packSize == 0) {
      fontAtlasImage = null;
      return;
    }

    final atlasOffset = arenaUint32[ArenaLayout.fontAtlasOffset ~/ 4];
    const int atlasWidth = 512;
    const int atlasHeight = 512;
    const int atlasBytes = atlasWidth * atlasHeight;

    // Validate that the atlas region is fully inside the Arena before reading
    // or passing it to the decoder.
    if (atlasOffset < 0 ||
        atlasOffset > _arenaSize - atlasBytes ||
        packSize < 0 ||
        packSize > _arenaSize) {
      debugPrint(
        'Font atlas region out of bounds: '
        'offset=$atlasOffset, packSize=$packSize, arenaSize=$_arenaSize',
      );
      fontAtlasImage = null;
      return;
    }

    final rawA8 = _arena!.cast<dffi.Uint8>() + atlasOffset;
    final Uint8List rgbaBytes = Uint8List(atlasBytes * 4);

    for (int i = 0; i < atlasBytes; i++) {
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
        count = _simulatedBuffer!.commandCount;
      }
    } else {
      // Single-clock sync: Flutter's Ticker is the only clock source.  Wake
      // the Rust simulation thread once per vsync; it will process the tick
      // asynchronously on its own core while we read the latest front buffer.
      _checkFfiResult(triggerEnginePulse(), 'trigger_engine_pulse');
      final backIndex = getBackIndex(_doubleBufferBridge!);
      count = (backIndex == 0)
          ? getBufferBCommandCount(_doubleBufferBridge!)
          : getBufferACommandCount(_doubleBufferBridge!);
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
      _checkFfiResult(res, 'load_resource_pack_raw');
      checkAndLoadFontAtlas();
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

  void sendInputEvent(int eventType, double x, double y) {
    _checkFfiResult(processInputEvent(eventType, x, y), 'process_input_event');
  }

  void setEntityCount(int count) {
    _checkFfiResult(setEntitiesCount(count), 'set_entities_count');
  }

  /// Safe entity initialisation.  Rust holds the Arena write lock for the
  /// duration of the call, so it cannot race the simulation tick.
  void configureEntity({
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
    final result = setEntity(
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
    _checkFfiResult(result, 'set_entity');
  }

  /// Safe Arena byte write.  The engine must be paused while performing
  /// multi-write setup to avoid torn state.
  void writeArenaString(int offset, Uint8List bytes) {
    if (!isNativeAvailable) return;
    final ptr = ffi.calloc<dffi.Uint8>(bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      _checkFfiResult(
        writeArenaBytes(offset, ptr, bytes.length),
        'write_arena_bytes',
      );
    } finally {
      ffi.calloc.free(ptr);
    }
  }

  /// Writes a [TextPayload] header followed by the string bytes into the Arena.
  /// The written offset is the pointer passed to `setEntity` as `strOffset`.
  void writeArenaText(
    int offset,
    double x,
    double y,
    double fontSize,
    Uint8List bytes,
  ) {
    if (!isNativeAvailable) return;
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
      _checkFfiResult(
        writeArenaBytes(offset, ptr, totalSize),
        'write_arena_bytes',
      );
    } finally {
      ffi.calloc.free(ptr);
    }
  }

  /// Frees every shared-memory buffer through the Rust allocator.  Must only
  /// be called after `shutdownEngine()` has returned and the simulation thread
  /// has exited, otherwise the engine could dereference freed memory.
  void _freeSharedMemory() {
    if (_doubleBufferBridge != null && _doubleBufferBridge != dffi.nullptr) {
      final commandsA = _doubleBufferBridge!.ref.bufferACommands;
      if (commandsA != dffi.nullptr) {
        malphasFree(
          commandsA.cast(),
          maxCommandBufferCapacity * dffi.sizeOf<DartRenderCommand>(),
        );
      }
      final commandsB = _doubleBufferBridge!.ref.bufferBCommands;
      if (commandsB != dffi.nullptr) {
        malphasFree(
          commandsB.cast(),
          maxCommandBufferCapacity * dffi.sizeOf<DartRenderCommand>(),
        );
      }
      malphasFree(
        _doubleBufferBridge!.cast(),
        dffi.sizeOf<MalphasDoubleBufferBridge>(),
      );
    }
    if (_arena != null && _arena != dffi.nullptr) {
      malphasFree(_arena!.cast<dffi.Uint8>(), _arenaSize);
    }
    _doubleBufferBridge = dffi.nullptr;
    _arena = dffi.nullptr;
  }

  @override
  void dispose() {
    if (isNativeAvailable) {
      try {
        final result = shutdownEngine();
        if (result >= 0) {
          _freeSharedMemory();
        } else {
          debugPrint(
            'MalphasBindings.dispose: shutdown_engine failed with code $result; '
            'shared memory not freed',
          );
        }
      } catch (e) {
        debugPrint('MalphasBindings.dispose error: $e');
      }
    }
    _simulatedBuffer?.dispose();
    _simulatedBuffer = null;
    fontAtlasImage?.dispose();
    fontAtlasImage = null;
    super.dispose();
  }
}

/// Fallback command buffer used when the native library cannot be loaded.
class SnapshotCommandBuffer {
  int commandCount = 0;
  dffi.Pointer<DartRenderCommand>? commands;

  SnapshotCommandBuffer() {
    commands = ffi.calloc<DartRenderCommand>(2);
  }

  void dispose() {
    if (commands != null) {
      ffi.calloc.free(commands!);
      commands = null;
    }
  }

  void executeSimulation() {
    commandCount = 1;
    commands![0].commandType = 1;
    commands![0].x = 250;
    commands![0].y = 250;
    commands![0].width = 500;
    commands![0].height = 500;
    commands![0].colorRgba = 0xFF1A1B1C;
  }
}

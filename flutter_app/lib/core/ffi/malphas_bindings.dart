import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'types.dart';

/// Zero-copy FFI gateway to the Rust `malphas_core` v2.7.5 engine.
///
/// The old arena-based entity setup API has been removed.  Systems now own all
/// simulation state; Flutter only drives the vsync pulse and reads the front
/// buffer of the shared double-buffer bridge.
class MalphasBindings extends ChangeNotifier {
  static final MalphasBindings _instance = MalphasBindings._internal();
  factory MalphasBindings() => _instance;
  MalphasBindings._internal() {
    _loadLibrary();
  }

  DynamicLibrary? _lib;
  Pointer<MalphasDoubleBufferBridge>? _bridge;

  bool _nativeAvailable = false;
  bool get isNativeAvailable => _nativeAvailable;

  Pointer<MalphasDoubleBufferBridge>? get bridge => _bridge;

  /// Reloads the native core from a new binary path.
  ///
  /// This is used by the engine manager hot-swap flow.  The old library handle
  /// is intentionally leaked because Dart's `DynamicLibrary` does not expose a
  /// close operation; the new handle becomes active immediately.
  void reloadNativeLibrary(String path) {
    try {
      final newLib = DynamicLibrary.open(path);
      _lib = newLib;
      _nativeAvailable = true;
      _bindFunctions();
      debugPrint('MalphasBindings: hot-swapped native library from $path');
    } catch (e) {
      debugPrint('MalphasBindings: failed to hot-swap native library: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Library loading.
  // ---------------------------------------------------------------------------
  void _loadLibrary() {
    final candidates = _libraryCandidates();
    for (final path in candidates) {
      try {
        _lib = DynamicLibrary.open(path);
        _nativeAvailable = true;
        _bindFunctions();
        debugPrint('MalphasBindings: loaded native library from $path');
        return;
      } catch (e) {
        debugPrint('MalphasBindings: failed to load $path ($e)');
      }
    }
    _nativeAvailable = false;
    debugPrint('MalphasBindings: no native library available');
  }

  List<String> _libraryCandidates() {
    final String binaryName;
    if (Platform.isWindows) {
      binaryName = 'malphas_core.dll';
    } else if (Platform.isMacOS) {
      binaryName = 'libmalphas_core.dylib';
    } else if (Platform.isAndroid) {
      // On Android the library is bundled under jniLibs and loaded by name.
      return ['libmalphas_core.so'];
    } else if (Platform.isIOS) {
      // iOS frameworks are loaded by name.
      return ['malphas_core.framework/malphas_core', 'libmalphas_core.dylib'];
    } else {
      binaryName = 'libmalphas_core.so';
    }

    final workspace = _findWorkspaceRoot();
    return [
      if (workspace != null) '$workspace/flutter_app/motors/$binaryName',
      if (workspace != null) '$workspace/target/release/$binaryName',
      if (workspace != null)
        '$workspace/malphas_core/target/release/$binaryName',
      if (workspace != null) '$workspace/$binaryName',
      binaryName,
    ];
  }

  String? _findWorkspaceRoot() {
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
    return null;
  }

  // ---------------------------------------------------------------------------
  // Native function bindings.
  // ---------------------------------------------------------------------------
  late final _InitEngine _initEngine;
  late final _ShutdownEngine _shutdownEngine;
  late final _PauseEngine _pauseEngine;
  late final _TriggerEnginePulse _triggerEnginePulse;
  late final _LoadMsp _loadMsp;
  late final _RefreshMsp _refreshMsp;
  late final _LoadSystem _loadSystem;
  late final _GetBackIndex _getBackIndex;
  late final _GetCommandsWritten _getCommandsWritten;
  late final _GetMspEntityCount _getMspEntityCount;
  late final _GetLoadedSystemCount _getLoadedSystemCount;
  late final _MalphasAlloc _malphasAlloc;
  late final _MalphasFree _malphasFree;
  late final _VerifyEngineSignature _verifyEngineSignature;
  late final _VerifyBinaryIntegrity _verifyBinaryIntegrity;
  late final _ProcessInputEvent _processInputEvent;
  late final _SetTrustAnchor _setTrustAnchor;
  late final _GetU64 _getVmTickMicros;
  late final _GetU64 _getPulseLatencyMicros;
  late final _GetU64 _getHitTestsCount;
  late final _GetU64 _getCommandsGeneratedCount;

  void _bindFunctions() {
    if (_lib == null) return;
    final lib = _lib!;

    _initEngine =
        lib.lookupFunction<_InitEngineNative, _InitEngine>('init_engine');
    _shutdownEngine =
        lib.lookupFunction<_ShutdownEngineNative, _ShutdownEngine>(
            'shutdown_engine');
    _pauseEngine =
        lib.lookupFunction<_PauseEngineNative, _PauseEngine>('pause_engine');
    _triggerEnginePulse =
        lib.lookupFunction<_TriggerEnginePulseNative, _TriggerEnginePulse>(
            'trigger_engine_pulse');
    _loadMsp = lib.lookupFunction<_LoadMspNative, _LoadMsp>('load_msp');
    _refreshMsp = lib.lookupFunction<_LoadMspNative, _LoadMsp>('refresh_msp');
    _loadSystem =
        lib.lookupFunction<_LoadMspNative, _LoadSystem>('load_system');
    _getBackIndex = lib
        .lookupFunction<_GetBackIndexNative, _GetBackIndex>('get_back_index');
    _getCommandsWritten =
        lib.lookupFunction<_GetCommandsWrittenNative, _GetCommandsWritten>(
            'get_commands_written');
    _getMspEntityCount =
        lib.lookupFunction<_GetMspEntityCountNative, _GetMspEntityCount>(
            'get_msp_entity_count');
    _getLoadedSystemCount =
        lib.lookupFunction<_GetLoadedSystemCountNative, _GetLoadedSystemCount>(
            'get_loaded_system_count');
    _malphasAlloc =
        lib.lookupFunction<_MalphasAllocNative, _MalphasAlloc>('malphas_alloc');
    _malphasFree =
        lib.lookupFunction<_MalphasFreeNative, _MalphasFree>('malphas_free');
    _verifyEngineSignature = lib.lookupFunction<_VerifyEngineSignatureNative,
        _VerifyEngineSignature>('verify_engine_signature');
    _verifyBinaryIntegrity = lib.lookupFunction<_VerifyBinaryIntegrityNative,
        _VerifyBinaryIntegrity>('verify_binary_integrity');
    _processInputEvent =
        lib.lookupFunction<_ProcessInputEventNative, _ProcessInputEvent>(
            'process_input_event');
    _setTrustAnchor =
        lib.lookupFunction<_SetTrustAnchorNative, _SetTrustAnchor>(
            'set_trust_anchor');
    _getVmTickMicros =
        lib.lookupFunction<_GetU64Native, _GetU64>('get_vm_tick_micros');
    _getPulseLatencyMicros =
        lib.lookupFunction<_GetU64Native, _GetU64>('get_pulse_latency_micros');
    _getHitTestsCount =
        lib.lookupFunction<_GetU64Native, _GetU64>('get_hit_tests_count');
    _getCommandsGeneratedCount = lib
        .lookupFunction<_GetU64Native, _GetU64>('get_commands_generated_count');
  }

  // ---------------------------------------------------------------------------
  // Engine lifecycle.
  // ---------------------------------------------------------------------------
  /// Initialises the engine and returns `0` on success or a negative error code.
  ///
  /// Rust allocates and owns the 64-byte aligned bridge and command buffers;
  /// Dart only receives the pointer and must treat it as read-only.
  int initEngine({int maxCommands = 2048}) {
    if (!_nativeAvailable || _lib == null) return -1;

    shutdownEngine();

    final bridgePtr = _initEngine(maxCommands);
    if (bridgePtr == nullptr) return -1;
    _bridge = bridgePtr.cast<MalphasDoubleBufferBridge>();
    return 0;
  }

  /// Tears down the engine thread and frees the Rust-owned bridge.
  int shutdownEngine() {
    if (!_nativeAvailable) return 0;
    final result = _shutdownEngine();
    _bridge = null;
    return result;
  }

  int pauseEngine(bool paused) =>
      _nativeAvailable ? _pauseEngine(paused ? 1 : 0) : 0;

  /// Sends one vsync pulse to the engine worker thread.
  int triggerEnginePulse() {
    if (!_nativeAvailable) return -1;
    return _triggerEnginePulse();
  }

  // ---------------------------------------------------------------------------
  // MSP / system loading.
  // ---------------------------------------------------------------------------
  int loadMsp(String path) {
    if (!_nativeAvailable) return -1;
    return using((arena) {
      final cPath = path.toNativeUtf8(allocator: arena);
      return _loadMsp(cPath);
    });
  }

  /// Hot-swaps the mapped MSP without unloading loaded `.mxc` systems.
  int refreshMsp(String path) {
    if (!_nativeAvailable) return -1;
    return using((arena) {
      final cPath = path.toNativeUtf8(allocator: arena);
      return _refreshMsp(cPath);
    });
  }

  int loadSystem(String path) {
    if (!_nativeAvailable) return -1;
    return using((arena) {
      final cPath = path.toNativeUtf8(allocator: arena);
      return _loadSystem(cPath);
    });
  }

  // ---------------------------------------------------------------------------
  // Front buffer accessors used by PrimitiveCanvas (zero-copy).
  // ---------------------------------------------------------------------------
  Pointer<DartRenderCommand> get frontCommands {
    if (_bridge == null) return nullptr;
    final bridge = _bridge!.ref;
    return bridge.atomicBackIndex == 0
        ? bridge.bufferBCommands
        : bridge.bufferACommands;
  }

  int get frontCount {
    if (_bridge == null) return 0;
    final bridge = _bridge!.ref;
    return bridge.atomicBackIndex == 0
        ? bridge.bufferBCommandCount
        : bridge.bufferACommandCount;
  }

  /// Legacy alias for tests that previously read `commandCount`.
  int get commandCount => frontCount;

  /// Legacy alias for tests that previously read `commandsPointer`.
  Pointer<DartRenderCommand> get commandsPointer => frontCommands;

  int get commandsWritten =>
      _bridge == null ? 0 : _getCommandsWritten(_bridge!);

  int get backIndex => _bridge == null ? 0 : _getBackIndex(_bridge!);

  // ---------------------------------------------------------------------------
  // Aligned allocator.
  // ---------------------------------------------------------------------------
  Pointer<Uint8> malphasAlloc(int size) => _malphasAlloc(size);
  void malphasFree(Pointer<Uint8> ptr, int size) => _malphasFree(ptr, size);

  // ---------------------------------------------------------------------------
  // Integrity / signatures.
  // ---------------------------------------------------------------------------
  int verifyEngineSignature(
      String path, String signatureHex, String publicKeyHex) {
    if (!_nativeAvailable) return -1;
    return using((arena) {
      final cPath = path.toNativeUtf8(allocator: arena);
      final cSig = signatureHex.toNativeUtf8(allocator: arena);
      final cKey = publicKeyHex.toNativeUtf8(allocator: arena);
      return _verifyEngineSignature(cPath, cSig, cKey);
    });
  }

  int verifyBinaryIntegrity(String path, String expectedSha) {
    if (!_nativeAvailable) return -1;
    return using((arena) {
      final cPath = path.toNativeUtf8(allocator: arena);
      final cSha = expectedSha.toNativeUtf8(allocator: arena);
      return _verifyBinaryIntegrity(cPath, cSha);
    });
  }

  // ---------------------------------------------------------------------------
  // Input / telemetry.
  // ---------------------------------------------------------------------------
  int processInputEvent(int type, double x, double y) {
    if (!_nativeAvailable) return -1;
    return _processInputEvent(type, x, y);
  }

  /// Overrides the default test-only Ed25519 trust anchor used for `.msp` and
  /// `.mxc` signature verification.  Returns `0` on success.
  int setTrustAnchor(String publicKeyHex) {
    if (!_nativeAvailable) return -1;
    return using((arena) {
      final cKey = publicKeyHex.toNativeUtf8(allocator: arena);
      return _setTrustAnchor(cKey);
    });
  }

  int get vmTickMicros => _nativeAvailable ? _getVmTickMicros() : 0;
  int get pulseLatencyMicros => _nativeAvailable ? _getPulseLatencyMicros() : 0;
  int get hitTestsCount => _nativeAvailable ? _getHitTestsCount() : 0;
  int get commandsGeneratedCount =>
      _nativeAvailable ? _getCommandsGeneratedCount() : 0;

  int getMspEntityCount() => _nativeAvailable ? _getMspEntityCount() : 0;
  int getLoadedSystemCount() => _nativeAvailable ? _getLoadedSystemCount() : 0;
}

// ---------------------------------------------------------------------------
// Native / Dart function type definitions.
// ---------------------------------------------------------------------------
typedef _InitEngineNative = Pointer<MalphasDoubleBufferBridge> Function(Uint32);
typedef _InitEngine = Pointer<MalphasDoubleBufferBridge> Function(int);

typedef _ShutdownEngineNative = Int32 Function();
typedef _ShutdownEngine = int Function();

typedef _PauseEngineNative = Int32 Function(Int32);
typedef _PauseEngine = int Function(int);

typedef _TriggerEnginePulseNative = Int32 Function();
typedef _TriggerEnginePulse = int Function();

typedef _LoadMspNative = Int32 Function(Pointer<Utf8>);
typedef _LoadMsp = int Function(Pointer<Utf8>);
typedef _LoadSystem = int Function(Pointer<Utf8>);
typedef _RefreshMsp = int Function(Pointer<Utf8>);

typedef _GetBackIndexNative = Uint8 Function(
    Pointer<MalphasDoubleBufferBridge>);
typedef _GetBackIndex = int Function(Pointer<MalphasDoubleBufferBridge>);

typedef _GetCommandsWrittenNative = Uint32 Function(
    Pointer<MalphasDoubleBufferBridge>);
typedef _GetCommandsWritten = int Function(Pointer<MalphasDoubleBufferBridge>);

typedef _GetMspEntityCountNative = Uint32 Function();
typedef _GetMspEntityCount = int Function();

typedef _GetLoadedSystemCountNative = Uint32 Function();
typedef _GetLoadedSystemCount = int Function();

typedef _MalphasAllocNative = Pointer<Uint8> Function(IntPtr);
typedef _MalphasAlloc = Pointer<Uint8> Function(int);

typedef _MalphasFreeNative = Void Function(Pointer<Uint8>, IntPtr);
typedef _MalphasFree = void Function(Pointer<Uint8>, int);

typedef _VerifyEngineSignatureNative = Int32 Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _VerifyEngineSignature = int Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _VerifyBinaryIntegrityNative = Int32 Function(
    Pointer<Utf8>, Pointer<Utf8>);
typedef _VerifyBinaryIntegrity = int Function(Pointer<Utf8>, Pointer<Utf8>);

typedef _ProcessInputEventNative = Int32 Function(Int32, Float, Float);
typedef _ProcessInputEvent = int Function(int, double, double);

typedef _SetTrustAnchorNative = Int32 Function(Pointer<Utf8>);
typedef _SetTrustAnchor = int Function(Pointer<Utf8>);

typedef _GetU64Native = Uint64 Function();
typedef _GetU64 = int Function();

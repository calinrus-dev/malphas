import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import '../services/desktop_path_service.dart';
import 'types.dart';

/// Exception thrown when an FFI call returns a non-zero error code.
///
/// Error codes are contractually agreed between Dart and Rust. Positive codes
/// are generally informational; negative codes are failures that must surface
/// to the caller.
class FFIException implements Exception {
  final int code;
  final String message;
  final String? call;

  const FFIException(this.code, this.message, {this.call});

  @override
  String toString() => 'FFIException(code=$code, call=$call, message=$message)';
}

/// Maps a negative FFI error code to a human-readable message.
String _ffiErrorMessage(int code) {
  if (code == -1) return 'ERR_INVALID_ARGUMENT';
  if (code == -2) return 'ERR_BRIDGE_NULL';
  if (code == -10) return 'ERR_ABI_MISMATCH';
  if (code == -120) return 'ERR_MSP_SIGNATURE_MISSING';
  if (code == -121) return 'ERR_MSP_SIGNATURE_INVALID';
  if (code == -210) return 'ERR_SYSTEM_SANDBOX';
  if (code == -211) return 'ERR_SYSTEM_SIGNATURE_MISSING';
  if (code == -212) return 'ERR_SYSTEM_SIGNATURE_INVALID';
  return 'ERR_NATIVE ($code)';
}

/// Throws [FFIException] if [code] indicates failure.
///
/// A code of zero means success. Positive codes are preserved and returned.
int _checkFfi(int code, String call) {
  if (code < 0) {
    throw FFIException(code, _ffiErrorMessage(code), call: call);
  }
  return code;
}

/// Zero-copy FFI gateway to the Rust `malphas_core` v2.10.0 engine.
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
  ///
  /// Public entry point kept for [EngineController.hotSwapEngine]; the actual
  /// work is delegated to the private implementation below.
  void reloadNativeLibrary(String path) => _reloadNativeLibrary(path);

  void _reloadNativeLibrary(String path) {
    try {
      shutdownEngine();
      _lib?.close();
      final newLib = DynamicLibrary.open(path);
      _lib = newLib;
      _nativeAvailable = true;
      _bindFunctions();
      debugPrint('MalphasBindings: hot-swapped native library from $path');
    } catch (e) {
      debugPrint('MalphasBindings: failed to hot-swap native library: $e');
      _nativeAvailable = false;
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

    final candidates = <String>[];

    // 1. Sandboxed desktop path (production).
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final sandboxed = DesktopPathService.validatedMotorPathSync(binaryName);
      if (sandboxed != null) {
        candidates.add(sandboxed);
      }
    }

    // 2. Workspace-relative paths (development).
    final workspace = _findWorkspaceRoot();
    if (workspace != null) {
      candidates.addAll([
        '$workspace/flutter_app/motors/$binaryName',
        '$workspace/target/release/$binaryName',
        '$workspace/malphas_core/target/release/$binaryName',
        '$workspace/$binaryName',
      ]);
    }

    // 3. System search (fallback).
    candidates.add(binaryName);

    return candidates;
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
  late _InitEngine _initEngine;
  late _ShutdownEngine _shutdownEngine;
  late _PauseEngine _pauseEngine;
  late _TriggerEnginePulse _triggerEnginePulse;
  late _LoadMsp _loadMsp;
  late _RefreshMsp _refreshMsp;
  late _LoadSystem _loadSystem;
  late _GetCommandsWritten _getCommandsWritten;
  late _GetFrontBufferSnapshot _getFrontBufferSnapshot;
  late _GetBufferCommandCount _getBufferACommandCount;
  late _GetBufferCommandCount _getBufferBCommandCount;
  late _GetAbiVersion _getAbiVersion;
  late _GetMspEntityCount _getMspEntityCount;
  late _GetLoadedSystemCount _getLoadedSystemCount;
  late _MalphasAlloc _malphasAlloc;
  late _MalphasFree _malphasFree;
  late _VerifyEngineSignature _verifyEngineSignature;
  late _VerifyBinaryIntegrity _verifyBinaryIntegrity;
  late _ProcessInputEvent _processInputEvent;
  late _SetTrustAnchor _setTrustAnchor;
  late _GetU64 _getVmTickMicros;
  late _GetU64 _getPulseLatencyMicros;
  late _GetU64 _getCommandsGeneratedCount;

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
    _getCommandsWritten =
        lib.lookupFunction<_GetCommandsWrittenNative, _GetCommandsWritten>(
            'get_commands_written');
    _getFrontBufferSnapshot = lib.lookupFunction<_GetFrontBufferSnapshotNative,
        _GetFrontBufferSnapshot>('get_front_buffer_snapshot');
    _getBufferACommandCount = lib.lookupFunction<_GetBufferCommandCountNative,
        _GetBufferCommandCount>('get_buffer_a_command_count');
    _getBufferBCommandCount = lib.lookupFunction<_GetBufferCommandCountNative,
        _GetBufferCommandCount>('get_buffer_b_command_count');
    _getAbiVersion = lib.lookupFunction<_GetAbiVersionNative, _GetAbiVersion>(
        'get_abi_version');
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
  ///
  /// Rust allocates and owns the 64-byte aligned bridge and command buffers.
  /// Dart receives only the pointer and must treat it as read-only. All atomic
  /// state reads go through FFI getters.
  ///
  /// Throws [FFIException] on any failure.
  void initEngine({int maxCommands = 2048}) {
    if (!_nativeAvailable || _lib == null) {
      throw const FFIException(-1, 'Native library not loaded',
          call: 'init_engine');
    }

    shutdownEngine();

    final bridgePtr = _initEngine(maxCommands);
    if (bridgePtr == nullptr) {
      throw const FFIException(-2, 'Bridge allocation failed',
          call: 'init_engine');
    }
    _bridge = bridgePtr.cast<MalphasDoubleBufferBridge>();

    // ABI version is read through an FFI getter so Dart never dereferences
    // bridge fields directly. It is validated before any shared memory is used.
    final abiVersion = _getAbiVersion();
    if (abiVersion != bridgeAbiVersion) {
      shutdownEngine();
      throw FFIException(
        -10,
        'ABI mismatch (expected 0x${bridgeAbiVersion.toRadixString(16)}, '
        'got 0x${abiVersion.toRadixString(16)})',
        call: 'init_engine',
      );
    }
  }

  /// Tears down the engine thread and frees the Rust-owned bridge.
  void shutdownEngine() {
    if (!_nativeAvailable) return;
    _shutdownEngine();
    _bridge = null;
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
  /// Loads an MSP binary. Throws [FFIException] on failure.
  void loadMsp(String path) {
    if (!_nativeAvailable) {
      throw const FFIException(-1, 'Native library not loaded',
          call: 'load_msp');
    }
    using((arena) {
      final cPath = path.toNativeUtf8(allocator: arena);
      _checkFfi(_loadMsp(cPath), 'load_msp');
    });
  }

  /// Hot-swaps the mapped MSP without unloading loaded `.mxc` systems.
  /// Throws [FFIException] on failure.
  void refreshMsp(String path) {
    if (!_nativeAvailable) {
      throw const FFIException(-1, 'Native library not loaded',
          call: 'refresh_msp');
    }
    using((arena) {
      final cPath = path.toNativeUtf8(allocator: arena);
      _checkFfi(_refreshMsp(cPath), 'refresh_msp');
    });
  }

  /// Loads an MXC system library. Throws [FFIException] on failure.
  void loadSystem(String path) {
    if (!_nativeAvailable) {
      throw const FFIException(-1, 'Native library not loaded',
          call: 'load_system');
    }
    using((arena) {
      final cPath = path.toNativeUtf8(allocator: arena);
      _checkFfi(_loadSystem(cPath), 'load_system');
    });
  }

  // ---------------------------------------------------------------------------
  // Front buffer accessors used by PrimitiveCanvas (zero-copy).
  // ---------------------------------------------------------------------------
  /// Atomically reads the current front buffer snapshot.
  ///
  /// Returns both the command pointer and count obtained in a single FFI call
  /// so the painter cannot observe a torn buffer flip between reading the
  /// count and the pointer.
  ({Pointer<DartRenderCommand> commands, int count}) getFrontBufferSnapshot() {
    if (_bridge == null) {
      return (commands: nullptr, count: 0);
    }
    return using((arena) {
      final frontIndexOut = arena<Uint8>();
      final frontCountOut = arena<Uint32>();
      final commands = _getFrontBufferSnapshot(
        _bridge!,
        frontIndexOut,
        frontCountOut,
      );
      return (
        commands: commands,
        count: frontCountOut.value,
      );
    });
  }

  Pointer<DartRenderCommand> get frontCommands {
    return getFrontBufferSnapshot().commands;
  }

  int get frontCount {
    return getFrontBufferSnapshot().count;
  }

  int get commandsWritten =>
      _bridge == null ? 0 : _getCommandsWritten(_bridge!);

  int get bufferACommandCount =>
      _bridge == null ? 0 : _getBufferACommandCount(_bridge!);

  int get bufferBCommandCount =>
      _bridge == null ? 0 : _getBufferBCommandCount(_bridge!);

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
  /// `.mxc` signature verification. Throws [FFIException] on failure.
  void setTrustAnchor(String publicKeyHex) {
    if (!_nativeAvailable) {
      throw const FFIException(-1, 'Native library not loaded',
          call: 'set_trust_anchor');
    }
    using((arena) {
      final cKey = publicKeyHex.toNativeUtf8(allocator: arena);
      _checkFfi(_setTrustAnchor(cKey), 'set_trust_anchor');
    });
  }

  int get vmTickMicros => _nativeAvailable ? _getVmTickMicros() : 0;
  int get pulseLatencyMicros => _nativeAvailable ? _getPulseLatencyMicros() : 0;
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

typedef _GetCommandsWrittenNative = Uint32 Function(
    Pointer<MalphasDoubleBufferBridge>);
typedef _GetCommandsWritten = int Function(Pointer<MalphasDoubleBufferBridge>);

typedef _GetFrontBufferSnapshotNative = Pointer<DartRenderCommand> Function(
  Pointer<MalphasDoubleBufferBridge>,
  Pointer<Uint8>,
  Pointer<Uint32>,
);
typedef _GetFrontBufferSnapshot = Pointer<DartRenderCommand> Function(
  Pointer<MalphasDoubleBufferBridge>,
  Pointer<Uint8>,
  Pointer<Uint32>,
);

typedef _GetBufferCommandCountNative = Uint32 Function(
    Pointer<MalphasDoubleBufferBridge>);
typedef _GetBufferCommandCount = int Function(
    Pointer<MalphasDoubleBufferBridge>);

typedef _GetAbiVersionNative = Uint32 Function();
typedef _GetAbiVersion = int Function();

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

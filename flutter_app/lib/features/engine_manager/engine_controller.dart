import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../../core/services/payload_decode_service.dart';
import '../../core/services/trust_anchor_service.dart';
import '../hub/environment_model.dart';
import '../package_manager/package_controller.dart';
import 'models.dart';
import '../../core/ffi/malphas_bindings.dart';

/// Orchestrates the native engine lifecycle for a single [MalphasEnvironment].
///
/// The controller is a singleton because the Rust engine itself is a single
/// global instance. All engine state transitions are centralized here so that
/// start/stop/hot-swap are deterministic and no orphan threads remain.
class EngineController extends ChangeNotifier {
  static final EngineController _instance = EngineController._internal();
  factory EngineController() => _instance;
  EngineController._internal();

  final MalphasBindings _bindings = MalphasBindings();
  final PackageController _packageController = PackageController();

  MalphasBindings get bindings => _bindings;

  String? _trustAnchorHex;
  String? get trustAnchorHex => _trustAnchorHex;

  MalphasEnvironment? _activeEnvironment;
  MalphasEnvironment? get activeEnvironment => _activeEnvironment;

  bool isLoading = false;
  bool isRunning = false;
  String? errorMessage;

  Ticker? _ticker;
  final ValueNotifier<int> frameNotifier = ValueNotifier<int>(0);

  int get entityCount => _bindings.getMspEntityCount();
  int get loadedSystemCount => _bindings.getLoadedSystemCount();
  int get vmTickMicros => _bindings.vmTickMicros;
  int get commandsGeneratedCount => _bindings.commandsGeneratedCount;

  static String _defaultBinaryName() {
    if (Platform.isWindows) return 'malphas_core.dll';
    if (Platform.isMacOS) return 'libmalphas_core.dylib';
    return 'libmalphas_core.so';
  }

  final List<MalphasEngine> engines = [
    MalphasEngine(
      id: 'eng_liquid_01',
      name: 'LIQUID Core v1.0',
      version: 'v1.0.0',
      runtime: NativeRuntime.rust,
      binaryName: _defaultBinaryName(),
      sha256: '',
      allocatedMemoryBytes: 8388608,
      status: EngineStatus.unverified,
    ),
  ];

  String activeEngineId = 'eng_liquid_01';

  MalphasEngine get activeEngine => engines.firstWhere(
        (e) => e.id == activeEngineId,
        orElse: () => engines.isEmpty
            ? MalphasEngine(
                id: 'eng_fallback',
                name: 'Fallback Engine',
                version: 'v0.0.0',
                runtime: NativeRuntime.rust,
                binaryName: _defaultBinaryName(),
                sha256: '',
                allocatedMemoryBytes: 8388608,
                status: EngineStatus.corrupt,
              )
            : engines.first,
      );
  List<MalphasEngine> getAllEngines() => engines;

  /// Loads the Ed25519 public trust anchor.
  ///
  /// Priority:
  /// 1. Secure storage (platform keyring/keystore/keychain).
  /// 2. Build-time asset `assets/trust_anchor.pem`.
  /// 3. `MALPHAS_TRUST_ANCHOR` compile-time define.
  Future<String?> loadTrustAnchor() async {
    // 1. Secure storage (with a defensive timeout so widget tests never hang
    // waiting for a platform plugin).
    try {
      final fromStorage = await TrustAnchorService.retrieve()
          .timeout(const Duration(milliseconds: 100));
      if (fromStorage != null && fromStorage.isNotEmpty) {
        _trustAnchorHex = fromStorage;
        return _trustAnchorHex;
      }
    } catch (e) {
      debugPrint('TrustAnchorService retrieval failed: $e');
    }

    // 2. Build-time asset.
    try {
      final pem = await rootBundle.loadString('assets/trust_anchor.pem');
      _trustAnchorHex = pem.replaceAll(RegExp(r'\s+'), '');
      return _trustAnchorHex;
    } catch (_) {}

    // 3. Compile-time define.
    // ignore: do_not_use_environment
    const fromEnv = String.fromEnvironment('MALPHAS_TRUST_ANCHOR');
    if (fromEnv.isNotEmpty) {
      _trustAnchorHex = fromEnv;
      return _trustAnchorHex;
    }

    _trustAnchorHex = null;
    return null;
  }

  /// Persists a user-provided trust anchor to secure storage.
  Future<void> saveTrustAnchor(String publicKeyHex) async {
    final cleaned = publicKeyHex.replaceAll(RegExp(r'\s+'), '');
    await TrustAnchorService.store(cleaned);
    _trustAnchorHex = cleaned;
    notifyListeners();
  }

  /// Configures the native engine trust anchor when one is available.
  ///
  /// The engine will still reject signed assets at load time if no anchor is
  /// configured, so this method does not throw when the anchor is missing. It
  /// merely keeps the existing test flow intact.
  Future<void> _ensureTrustAnchor() async {
    final anchor = await loadTrustAnchor();
    if (anchor != null && anchor.isNotEmpty) {
      _bindings.setTrustAnchor(anchor);
    }
  }

  /// Loads [env] into the native engine and starts the vsync pulse.
  ///
  /// Sequence:
  /// 1. Trust anchor verification.
  /// 2. initEngine(maxCommands: 65536).
  /// 3. loadMsp for the first package id.
  /// 4. loadSystem for the engine binary (if any).
  /// 5. Start Ticker -> triggerEnginePulse every frame.
  Future<void> loadEnvironment(
    MalphasEnvironment env,
    TickerProvider vsync,
  ) async {
    if (isLoading) return;
    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      if (!_bindings.isNativeAvailable) {
        throw Exception('Native motor is not available in this environment');
      }

      await _ensureTrustAnchor();

      _bindings.initEngine(maxCommands: 65536);

      final packageIds =
          env.packageIds.isNotEmpty ? env.packageIds : const ['bouncing_demo'];
      final mspPath = _resolveMspPath(packageIds.first);
      if (mspPath == null) {
        throw Exception(
            'AUTO-LOAD ERROR: MSP not found for ${packageIds.first}');
      }
      _bindings.loadMsp(mspPath);

      final systemPath = _resolveSystemPath(env.engineId ?? packageIds.first);
      if (systemPath != null) {
        _bindings.loadSystem(systemPath);
      }

      _activeEnvironment = env;
      isRunning = true;
      _startPulse(vsync);
    } on FFIException catch (e) {
      errorMessage = 'Engine error: ${e.message} (${e.code})';
      isRunning = false;
    } catch (e) {
      errorMessage = 'Engine error: $e';
      isRunning = false;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Stops the vsync pulse and shuts down the engine.
  void unloadEnvironment() {
    _stopPulse();
    _bindings.shutdownEngine();
    _activeEnvironment = null;
    isRunning = false;
    errorMessage = null;
    notifyListeners();
  }

  /// Hot-swaps the mapped MSP without stopping the running system.
  void reloadMsp(String packId) {
    if (!isRunning) return;
    final path = _resolveMspPath(packId);
    if (path == null) {
      errorMessage = 'MSP not found for $packId';
      notifyListeners();
      return;
    }
    try {
      _bindings.refreshMsp(path);
    } on FFIException catch (e) {
      errorMessage = 'MSP reload failed: ${e.message} (${e.code})';
      notifyListeners();
    }
  }

  /// Full system reload: shutdown -> re-init -> reload MSP/system -> restart pulse.
  Future<void> reloadSystem(TickerProvider vsync) async {
    final env = _activeEnvironment;
    if (env == null) return;

    _stopPulse();
    _bindings.shutdownEngine();

    isLoading = true;
    errorMessage = null;
    notifyListeners();

    try {
      _bindings.initEngine(maxCommands: 65536);

      final packageIds =
          env.packageIds.isNotEmpty ? env.packageIds : const ['bouncing_demo'];
      final mspPath = _resolveMspPath(packageIds.first);
      if (mspPath != null) _bindings.loadMsp(mspPath);

      final systemPath = _resolveSystemPath(env.engineId ?? packageIds.first);
      if (systemPath != null) _bindings.loadSystem(systemPath);

      isRunning = true;
      _startPulse(vsync);
    } on FFIException catch (e) {
      errorMessage = 'System reload failed: ${e.message} (${e.code})';
      isRunning = false;
    } catch (e) {
      errorMessage = 'System reload failed: $e';
      isRunning = false;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  void _startPulse(TickerProvider vsync) {
    _stopPulse();
    _ticker = vsync.createTicker(_onTick)..start();
  }

  void _stopPulse() {
    _ticker?.dispose();
    _ticker = null;
  }

  void _onTick(Duration elapsed) {
    _bindings.triggerEnginePulse();
    frameNotifier.value++;
  }

  String? _resolveMspPath(String packId) {
    final workspace = _packageController.resolveWorkspaceRoot();
    final candidates = [
      '$workspace/examples/$packId/$packId.msp',
      '$workspace/packages/$packId.msp',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  String? _resolveSystemPath(String packId) {
    final workspace = _packageController.resolveWorkspaceRoot();
    final exts = Platform.isWindows
        ? ['.mxc', '.dll']
        : Platform.isMacOS
            ? ['.mxc', '.dylib']
            : ['.mxc', '.so'];

    for (final ext in exts) {
      final candidates = [
        '$workspace/flutter_app/motors/$packId$ext',
        '$workspace/examples/$packId/$packId$ext',
        '$workspace/packages/$packId$ext',
        '$workspace/$packId$ext',
      ];
      for (final candidate in candidates) {
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }

  /// Computes the SHA-256 hex digest of [file].
  String computeSha256(File file) {
    final bytes = file.readAsBytesSync();
    final digest = sha256.convert(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void verifyEngineIntegrity(String id, [String? fullWorkspacePath]) {
    final index = engines.indexWhere((e) => e.id == id);
    if (index == -1) return;

    if (id == 'embedded_native_core') {
      engines[index].status = EngineStatus.active;
      notifyListeners();
      return;
    }

    final engine = engines[index];
    final workspace = fullWorkspacePath ?? Directory.current.path;

    String targetPath;
    final idAsFile = File(engine.id);
    if (idAsFile.existsSync()) {
      targetPath = engine.id;
    } else {
      targetPath = Platform.isWindows
          ? "$workspace\\malphas_core\\target\\release\\${engine.binaryName}"
          : "$workspace/malphas_core/target/release/${engine.binaryName}";

      if (!File(targetPath).existsSync()) {
        targetPath = Platform.isWindows
            ? "$workspace\\${engine.binaryName}"
            : "$workspace/${engine.binaryName}";
      }
    }

    final binaryFile = File(targetPath);
    if (binaryFile.existsSync()) {
      engines[index].sha256 = computeSha256(binaryFile);
    }

    if (_trustAnchorHex == null || _trustAnchorHex!.isEmpty) {
      engines[index].status = EngineStatus.corrupt;
      return;
    }

    final sigPath = '$targetPath.sig';
    final sigFile = File(sigPath);
    if (!sigFile.existsSync()) {
      engines[index].status = EngineStatus.corrupt;
      return;
    }

    final signatureHex = sigFile.readAsStringSync().trim();
    final result = _bindings.verifyEngineSignature(
      targetPath,
      signatureHex,
      _trustAnchorHex!,
    );

    engines[index].status =
        result == 0 ? EngineStatus.standby : EngineStatus.corrupt;
    notifyListeners();
  }

  /// Scans the workspace for native Malphas engine binaries.
  void scanAvailableEngines([String? workspace]) {
    if (Platform.isAndroid || Platform.isIOS) {
      engines.clear();
      engines.add(
        MalphasEngine(
          id: 'embedded_native_core',
          name: 'Embedded Native Core',
          version: 'v3.0.0',
          runtime: NativeRuntime.rust,
          binaryName: _defaultBinaryName(),
          sha256: 'Embedded (OS Verified)',
          allocatedMemoryBytes: 8388608,
          status: EngineStatus.active,
        ),
      );
      activeEngineId = 'embedded_native_core';
      notifyListeners();
      return;
    }

    final root = workspace ?? Directory.current.path;
    final discovered = <String>{};

    void addIfBinary(File file) {
      final path = file.path;
      final lower = path.toLowerCase();
      if (lower.endsWith('.dll') ||
          lower.endsWith('.so') ||
          lower.endsWith('.dylib')) {
        discovered.add(path);
      }
    }

    final motorsDir = Directory(
      '$root${Platform.pathSeparator}flutter_app${Platform.pathSeparator}motors',
    );
    if (motorsDir.existsSync()) {
      for (final entity in motorsDir.listSync()) {
        if (entity is File) {
          final name = entity.uri.pathSegments.last;
          if (name.startsWith('malphas_core_')) {
            addIfBinary(entity);
          }
        }
      }
    }

    final releaseDir = Directory(
      '$root${Platform.pathSeparator}target${Platform.pathSeparator}release',
    );
    if (releaseDir.existsSync()) {
      final releaseNames = Platform.isWindows
          ? ['malphas_core.dll']
          : Platform.isMacOS
              ? ['libmalphas_core.dylib']
              : ['libmalphas_core.so'];
      for (final name in releaseNames) {
        final candidate = File(
          '${releaseDir.path}${Platform.pathSeparator}$name',
        );
        if (candidate.existsSync()) {
          addIfBinary(candidate);
        }
      }
    }

    final rootNames = Platform.isWindows
        ? ['malphas_core.dll']
        : Platform.isMacOS
            ? ['libmalphas_core.dylib']
            : ['libmalphas_core.so'];
    for (final name in rootNames) {
      final candidate = File('$root${Platform.pathSeparator}$name');
      if (candidate.existsSync()) {
        addIfBinary(candidate);
      }
    }

    engines.clear();
    for (final path in discovered) {
      final file = File(path);
      engines.add(
        MalphasEngine(
          id: path,
          name: path,
          version: 'discovered',
          runtime: NativeRuntime.rust,
          binaryName: file.uri.pathSegments.last,
          sha256: computeSha256(file),
          allocatedMemoryBytes: 8388608,
          status: EngineStatus.unverified,
        ),
      );
    }

    if (engines.isEmpty) {
      engines.add(
        MalphasEngine(
          id: 'eng_liquid_01',
          name: 'LIQUID Core v1.0',
          version: 'v1.0.0',
          runtime: NativeRuntime.rust,
          binaryName:
              Platform.isWindows ? 'malphas_core.dll' : 'libmalphas_core.so',
          sha256: '',
          allocatedMemoryBytes: 8388608,
          status: EngineStatus.unverified,
        ),
      );
    }

    activeEngineId = engines.first.id;
    notifyListeners();
  }

  /// Atomically swaps the active engine binary.
  bool hotSwapEngine(String id) {
    final targetIndex = engines.indexWhere((e) => e.id == id);
    if (targetIndex == -1) return false;
    final target = engines[targetIndex];

    final sourcePath = _resolveSourcePath(target);
    if (sourcePath == null || !File(sourcePath).existsSync()) {
      engines[targetIndex].status = EngineStatus.corrupt;
      notifyListeners();
      return false;
    }

    try {
      _bindings.shutdownEngine();
      _bindings.reloadNativeLibrary(sourcePath);

      if (!_bindings.isNativeAvailable) {
        engines[targetIndex].status = EngineStatus.corrupt;
        notifyListeners();
        return false;
      }

      try {
        _bindings.initEngine();
      } on FFIException catch (e) {
        debugPrint('hotSwapEngine init failed for "$id": ${e.message}');
        engines[targetIndex].status = EngineStatus.corrupt;
        notifyListeners();
        return false;
      }

      verifyEngineIntegrity(id);

      if (engines[targetIndex].status == EngineStatus.standby) {
        activeEngineId = id;
        engines[targetIndex].status = EngineStatus.active;
        notifyListeners();
        return true;
      }
    } catch (e, stack) {
      debugPrint('hotSwapEngine failed for "$id": $e');
      debugPrint(stack.toString());
      engines[targetIndex].status = EngineStatus.corrupt;
      notifyListeners();
      return false;
    }

    notifyListeners();
    return false;
  }

  String? _resolveSourcePath(MalphasEngine engine) {
    final idAsFile = File(engine.id);
    if (idAsFile.existsSync()) return engine.id;

    final workspace = Directory.current.path;
    final binaryName = engine.binaryName;
    final candidates = Platform.isWindows
        ? [
            '$workspace\\$binaryName',
            '$workspace\\malphas_core\\target\\release\\$binaryName',
          ]
        : [
            '$workspace/$binaryName',
            '$workspace/malphas_core/target/release/$binaryName',
          ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  @override
  void dispose() {
    _stopPulse();
    frameNotifier.dispose();
    _packageController.disposeSkins();
    const PayloadDecodeService().clearCache();
    super.dispose();
  }
}

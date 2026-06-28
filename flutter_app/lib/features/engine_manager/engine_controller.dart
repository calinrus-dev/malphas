import 'dart:io';
import 'package:crypto/crypto.dart';
import 'models.dart';
import '../../core/ffi/malphas_bindings.dart';

class EngineController {
  static final EngineController _instance = EngineController._internal();
  factory EngineController() => _instance;

  EngineController._internal();

  // MALPHAS REINFORCED v2.2 Phase 6 — Ed25519 public key for engine
  // signature verification. This is the test key generated for local builds.
  // Public key hex: d6bb3217a16e68819a37f68488c4f3726bc97cdd8b7e7a5b15d77bcdf0e63dab
  static const String _enginePublicKeyHex =
      'd6bb3217a16e68819a37f68488c4f3726bc97cdd8b7e7a5b15d77bcdf0e63dab';

  final List<MalphasEngine> engines = [
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
  ];

  String activeEngineId = 'eng_liquid_01';
  final MalphasBindings _bindings = MalphasBindings();

  MalphasEngine get activeEngine =>
      engines.firstWhere((e) => e.id == activeEngineId);
  List<MalphasEngine> getAllEngines() => engines;

  /// Computes the SHA-256 hex digest of [file].
  String computeSha256(File file) {
    final bytes = file.readAsBytesSync();
    final digest = sha256.convert(bytes);
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void verifyEngineIntegrity(String id, [String? fullWorkspacePath]) {
    final index = engines.indexWhere((e) => e.id == id);
    if (index == -1) return;

    final engine = engines[index];

    // Resolve workspace root directory dynamically
    final workspace = fullWorkspacePath ?? Directory.current.path;

    String targetPath;

    // If the engine id is itself an existing binary path (discovered by scan),
    // use it directly.
    final idAsFile = File(engine.id);
    if (idAsFile.existsSync()) {
      targetPath = engine.id;
    } else {
      // Construct target paths
      targetPath = Platform.isWindows
          ? "$workspace\\malphas_core\\target\\release\\${engine.binaryName}"
          : "$workspace/malphas_core/target/release/${engine.binaryName}";

      // Check fallback location (e.g. root workspace or app folder) if release target doesn't exist
      if (!File(targetPath).existsSync()) {
        targetPath = Platform.isWindows
            ? "$workspace\\${engine.binaryName}"
            : "$workspace/${engine.binaryName}";
      }
    }

    // Compute the real SHA-256 of the resolved binary.
    final binaryFile = File(targetPath);
    if (binaryFile.existsSync()) {
      engines[index].sha256 = computeSha256(binaryFile);
    }

    // MALPHAS REINFORCED v2.2 Phase 6 — Ed25519 signature verification.
    // A companion .sig file must exist next to the engine binary.
    final sigPath = '$targetPath.sig';
    final sigFile = File(sigPath);
    if (!sigFile.existsSync()) {
      engines[index].status = EngineStatus.corrupt;
      return;
    }

    final signatureHex = sigFile.readAsStringSync().trim();
    final result =
        _bindings.verifyEngine(targetPath, signatureHex, _enginePublicKeyHex);

    if (result == 0) {
      engines[index].status = EngineStatus.standby;
    } else {
      engines[index].status = EngineStatus.corrupt;
    }
  }

  /// Scans the workspace for native Malphas engine binaries and populates
  /// [engines] with one entry per discovered file. The original fallback entry
  /// is kept only when no binary is found.
  void scanAvailableEngines([String? workspace]) {
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

    // 1. flutter_app/motors/malphas_core_*.{dll,so,dylib}
    final motorsDir = Directory(
        '$root${Platform.pathSeparator}flutter_app${Platform.pathSeparator}motors');
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

    // 2. target/release/{malphas_core.dll,libmalphas_core.so,libmalphas_core.dylib}
    final releaseDir = Directory(
        '$root${Platform.pathSeparator}target${Platform.pathSeparator}release');
    if (releaseDir.existsSync()) {
      final releaseNames = Platform.isWindows
          ? ['malphas_core.dll']
          : Platform.isMacOS
              ? ['libmalphas_core.dylib']
              : ['libmalphas_core.so'];
      for (final name in releaseNames) {
        final candidate =
            File('${releaseDir.path}${Platform.pathSeparator}$name');
        if (candidate.existsSync()) {
          addIfBinary(candidate);
        }
      }
    }

    // 3. workspace root {malphas_core.dll,libmalphas_core.so,libmalphas_core.dylib}
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
  }

  bool hotSwapEngine(String id) {
    final target = engines.firstWhere((e) => e.id == id);
    if (target.status == EngineStatus.standby ||
        target.status == EngineStatus.active) {
      activeEngineId = id;
      target.status = EngineStatus.active;
      return true;
    }
    return false;
  }

  /// Reloads the native core from disk.  This tears down the current engine
  /// thread, frees shared memory, discards any unlocked temp binaries, loads
  /// the requested binary under a unique filename (bypassing the Dart/Windows
  /// DLL cache), and reinitialises the FFI bridge.
  void reloadNativeCore(String sourcePath) {
    _bindings.reloadNativeLibrary(sourcePath);
  }
}

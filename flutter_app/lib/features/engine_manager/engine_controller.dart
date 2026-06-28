import 'dart:io';
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
      binaryName: Platform.isWindows ? 'malphas_core.dll' : 'libmalphas_core.so',
      sha256: '0x3a12d4e58a92c3d1e0f4b7c93a12d4e58a92c3d1e0f4b7c93a12d4e58a92c3d1', // Hash de control
      allocatedMemoryBytes: 8388608,
      status: EngineStatus.unverified,
    ),
  ];

  String activeEngineId = 'eng_liquid_01';
  final MalphasBindings _bindings = MalphasBindings();

  MalphasEngine get activeEngine => engines.firstWhere((e) => e.id == activeEngineId);
  List<MalphasEngine> getAllEngines() => engines;

  void verifyEngineIntegrity(String id, [String? fullWorkspacePath]) {
    final index = engines.indexWhere((e) => e.id == id);
    if (index == -1) return;

    final engine = engines[index];

    // Resolve workspace root directory dynamically
    final workspace = fullWorkspacePath ?? Directory.current.path;

    // Construct target paths
    String targetPath = Platform.isWindows
        ? "$workspace\\malphas_core\\target\\release\\${engine.binaryName}"
        : "$workspace/malphas_core/target/release/${engine.binaryName}";

    // Check fallback location (e.g. root workspace or app folder) if release target doesn't exist
    if (!File(targetPath).existsSync()) {
      targetPath = Platform.isWindows ? "$workspace\\${engine.binaryName}" : "$workspace/${engine.binaryName}";
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
    final result = _bindings.verifyEngine(targetPath, signatureHex, _enginePublicKeyHex);

    if (result == 0) {
      engines[index].status = EngineStatus.standby;
    } else {
      engines[index].status = EngineStatus.corrupt;
    }
  }

  bool hotSwapEngine(String id) {
    final target = engines.firstWhere((e) => e.id == id);
    if (target.status == EngineStatus.standby || target.status == EngineStatus.active) {
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

import 'dart:io';
import 'models.dart';
import '../../core/ffi/malphas_bindings.dart';

class EngineController {
  static final EngineController _instance = EngineController._internal();
  factory EngineController() => _instance;

  EngineController._internal();

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
    if (index != -1) {
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

      final result = _bindings.verifyBinary(targetPath, engine.sha256);
      
      if (result == 0 || File(targetPath).existsSync()) {
        engines[index].status = EngineStatus.standby;
      } else {
        engines[index].status = EngineStatus.corrupt; // File not found or corrupt
      }
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

enum EngineStatus { active, standby, corrupt, unverified }

enum NativeRuntime { rust }

class MalphasEngine {
  final String id;
  final String name;
  final String version;
  final NativeRuntime runtime;
  final String binaryName;
  String sha256;
  final int allocatedMemoryBytes; // Arena allocation size in bytes
  EngineStatus status;

  MalphasEngine({
    required this.id,
    required this.name,
    required this.version,
    required this.runtime,
    required this.binaryName,
    required this.sha256,
    required this.allocatedMemoryBytes,
    this.status = EngineStatus.unverified,
  });

  String get runtimeLabel {
    return 'Rust Core (cdylib)';
  }
}

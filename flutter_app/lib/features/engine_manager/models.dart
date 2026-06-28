enum EngineStatus { active, standby, corrupt, unverified }

enum NativeRuntime { rust, zig, cpp }

class MalphasEngine {
  final String id;
  final String name;
  final String version;
  final NativeRuntime runtime;
  final String binaryName;
  String sha256;
  final int allocatedMemoryBytes; // Simulación de la Arena
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
    switch (runtime) {
      case NativeRuntime.rust:
        return 'Rust Core (cdylib)';
      case NativeRuntime.zig:
        return 'Zig native (C-ABI)';
      case NativeRuntime.cpp:
        return 'C++ Bare-Metal';
    }
  }
}

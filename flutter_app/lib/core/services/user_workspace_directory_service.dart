import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'app_state_persistence_service.dart';

/// Service that owns the user's configurable workspace directory.
///
/// The user directory is the root where Malphas stores user-created packages,
/// environments and system binaries.  On mobile it defaults to a platform
/// documents subdirectory (`Malphas`).  On desktop it can be changed via the
/// settings screen and is persisted across launches.
class UserWorkspaceDirectoryService {
  static final UserWorkspaceDirectoryService _instance =
      UserWorkspaceDirectoryService._internal();
  factory UserWorkspaceDirectoryService() => _instance;
  UserWorkspaceDirectoryService._internal();

  final AppStatePersistenceService _persistence = AppStatePersistenceService();

  String? _overrideDirectory;

  /// Test hook that bypasses path_provider and persistence.
  void setOverrideDirectory(String path) {
    _overrideDirectory = p.canonicalize(path);
  }

  void clearOverrideDirectory() {
    _overrideDirectory = null;
  }

  /// Resolves the absolute, canonical workspace root.
  ///
  /// Priority:
  /// 1. In-memory test override.
  /// 2. Persisted user directory override.
  /// 3. Development repository root (detected by `Cargo.toml`).
  /// 4. Platform default (`Documents/Malphas`).
  Future<String> resolveUserWorkspaceRoot() async {
    if (_overrideDirectory != null) return _overrideDirectory!;

    final persisted = await _persistence.loadUserWorkspaceDirectory();
    if (persisted != null && persisted.isNotEmpty) {
      return _ensureExists(persisted);
    }

    final repoRoot = _detectRepositoryRoot();
    if (repoRoot != null) {
      return _ensureExists(repoRoot);
    }

    final docs = await getApplicationDocumentsDirectory();
    final defaultPath = p.join(docs.path, 'Malphas');
    return _ensureExists(defaultPath);
  }

  /// Synchronous variant for paths that have already been resolved.
  ///
  /// Falls back to the detected repository root or current working directory
  /// only in headless contexts where neither the override nor path_provider
  /// have been initialized.
  String resolveUserWorkspaceRootSync() {
    if (_overrideDirectory != null) return _overrideDirectory!;

    final persisted = _persistence.loadUserWorkspaceDirectorySync();
    if (persisted != null && persisted.isNotEmpty) {
      return _ensureExists(persisted);
    }

    final repoRoot = _detectRepositoryRoot();
    if (repoRoot != null) return _ensureExists(repoRoot);

    return Directory.current.path;
  }

  /// Sets the user workspace directory and persists it.
  Future<void> setUserWorkspaceDirectory(String path) async {
    final canonical = p.canonicalize(path);
    await _persistence.saveUserWorkspaceDirectory(canonical);
  }

  /// Resets to the platform default.
  Future<void> resetToDefault() async {
    await _persistence.saveUserWorkspaceDirectory(null);
  }

  /// Detects the Malphas repository root from the current working directory.
  ///
  /// This makes desktop development and widget tests work out of the box while
  /// production installs fall back to the platform documents directory.
  String? _detectRepositoryRoot() {
    final current = Directory.current.path;
    final separator = Platform.pathSeparator;
    final parts = current.split(separator);
    for (int i = parts.length; i > 0; i--) {
      final candidate = parts.sublist(0, i).join(separator);
      if (File(p.join(candidate, 'Cargo.toml')).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  String _ensureExists(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return p.canonicalize(dir.path);
  }
}

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../features/hub/environment_model.dart';

/// Persists lightweight app state (environments and the package registry ids)
/// as JSON files in the application documents directory.
///
/// Heavy binary data (compiled .msp/.mxc packs and engine motors) stays on
/// disk where it already lives; only the references that the UI needs to
/// restore its state are saved here.
class AppStatePersistenceService {
  static final AppStatePersistenceService _instance =
      AppStatePersistenceService._internal();
  factory AppStatePersistenceService() => _instance;
  AppStatePersistenceService._internal();

  String? _overrideDocumentsDirectory;

  /// Allows tests to inject a temporary directory so [path_provider] is not
  /// required to be initialized in headless environments.
  void setDocumentsDirectoryOverride(String path) {
    _overrideDocumentsDirectory = path;
  }

  void clearDocumentsDirectoryOverride() {
    _overrideDocumentsDirectory = null;
  }

  Directory? _cachedDocumentsDirectory;

  Future<Directory> _documentsDirectory() async {
    if (_overrideDocumentsDirectory != null) {
      return Directory(_overrideDocumentsDirectory!);
    }
    _cachedDocumentsDirectory ??= await getApplicationDocumentsDirectory();
    return _cachedDocumentsDirectory!;
  }

  Future<File> _stateFile(String name) async {
    final dir = await _documentsDirectory();
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return File('${dir.path}/malphas_$name.json');
  }

  /// Saves the list of environments.
  Future<void> saveEnvironments(List<MalphasEnvironment> environments) async {
    final file = await _stateFile('environments');
    final jsonList = environments.map((e) => e.toJson()).toList();
    file.writeAsStringSync(jsonEncode(jsonList));
  }

  /// Loads the saved environments, or an empty list if none exist.
  Future<List<MalphasEnvironment>> loadEnvironments() async {
    try {
      final file = await _stateFile('environments');
      if (!file.existsSync()) return [];
      final jsonList = jsonDecode(file.readAsStringSync()) as List<dynamic>;
      return jsonList
          .map((e) => MalphasEnvironment.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      // A corrupted state file is not fatal; start fresh.
      return [];
    }
  }

  /// Saves the ids of the packages that are currently registered.
  Future<void> saveRegistryIds(List<String> packageIds) async {
    final file = await _stateFile('registry');
    file.writeAsStringSync(jsonEncode(packageIds));
  }

  /// Loads the saved registry ids, or an empty list if none exist.
  Future<List<String>> loadRegistryIds() async {
    try {
      final file = await _stateFile('registry');
      if (!file.existsSync()) return [];
      final jsonList = jsonDecode(file.readAsStringSync()) as List<dynamic>;
      return jsonList.map((e) => e as String).toList();
    } catch (e) {
      return [];
    }
  }

  /// Saves the custom workspace root override.
  Future<void> saveWorkspaceRootOverride(String? path) async {
    final file = await _stateFile('workspace_root');
    if (path == null) {
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    } else {
      file.writeAsStringSync(path);
    }
  }

  /// Loads the custom workspace root override.
  Future<String?> loadWorkspaceRootOverride() async {
    try {
      final file = await _stateFile('workspace_root');
      if (!file.existsSync()) return null;
      return file.readAsStringSync().trim();
    } catch (_) {
      return null;
    }
  }

  /// Saves the user-configurable workspace directory path.
  Future<void> saveUserWorkspaceDirectory(String? path) async {
    final file = await _stateFile('user_workspace_directory');
    if (path == null) {
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    } else {
      file.writeAsStringSync(path);
    }
  }

  /// Loads the user-configurable workspace directory path.
  Future<String?> loadUserWorkspaceDirectory() async {
    try {
      final file = await _stateFile('user_workspace_directory');
      if (!file.existsSync()) return null;
      return file.readAsStringSync().trim();
    } catch (_) {
      return null;
    }
  }

  /// Synchronous loader for contexts that cannot await persistence I/O.
  String? loadUserWorkspaceDirectorySync() {
    try {
      if (_overrideDocumentsDirectory == null) return null;
      final file = File(
          '$_overrideDocumentsDirectory/malphas_user_workspace_directory.json');
      if (!file.existsSync()) return null;
      return file.readAsStringSync().trim();
    } catch (_) {
      return null;
    }
  }

  Future<void> saveTelemetryOverlayEnabled(bool enabled) async {
    final file = await _stateFile('telemetry_overlay_enabled');
    file.writeAsStringSync(enabled ? '1' : '0');
  }

  Future<bool> loadTelemetryOverlayEnabled() async {
    try {
      final file = await _stateFile('telemetry_overlay_enabled');
      if (!file.existsSync()) return false;
      return file.readAsStringSync().trim() == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> saveTelemetryGpsEnabled(bool enabled) async {
    final file = await _stateFile('telemetry_gps_enabled');
    file.writeAsStringSync(enabled ? '1' : '0');
  }

  Future<bool> loadTelemetryGpsEnabled() async {
    try {
      final file = await _stateFile('telemetry_gps_enabled');
      if (!file.existsSync()) return false;
      return file.readAsStringSync().trim() == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> saveSplashShown() async {
    final file = await _stateFile('splash_shown');
    file.writeAsStringSync('1');
  }

  Future<bool> loadSplashShown() async {
    try {
      final file = await _stateFile('splash_shown');
      if (!file.existsSync()) return false;
      return file.readAsStringSync().trim() == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> saveOnboardingCompleted() async {
    final file = await _stateFile('onboarding_completed');
    file.writeAsStringSync('1');
  }

  Future<bool> loadOnboardingCompleted() async {
    try {
      final file = await _stateFile('onboarding_completed');
      if (!file.existsSync()) return false;
      return file.readAsStringSync().trim() == '1';
    } catch (_) {
      return false;
    }
  }
}

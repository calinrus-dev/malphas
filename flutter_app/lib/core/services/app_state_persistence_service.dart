import 'dart:convert';
import 'dart:io';
import '../../features/hub/environment_model.dart';

/// Persists lightweight app state (environments and the package registry ids)
/// as JSON files in the application documents directory.
///
/// Heavy binary data (compiled .mhp/.msp packs and engine motors) stays on
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

  Directory _documentsDirectory() {
    if (_overrideDocumentsDirectory != null) {
      return Directory(_overrideDocumentsDirectory!);
    }
    // Synchronous fallback: path_provider is not always initialized in tests,
    // so we use a directory next to the current working directory. Production
    // builds should set an override if they need a different location.
    final cwd = Directory.current.path;
    final fallback = Directory('$cwd/malphas_state');
    if (!fallback.existsSync()) {
      fallback.createSync(recursive: true);
    }
    return fallback;
  }

  File _stateFile(String name) {
    final dir = _documentsDirectory();
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return File('${dir.path}/malphas_$name.json');
  }

  /// Saves the list of environments.
  void saveEnvironments(List<MalphasEnvironment> environments) {
    final file = _stateFile('environments');
    final jsonList = environments.map((e) => e.toJson()).toList();
    file.writeAsStringSync(jsonEncode(jsonList));
  }

  /// Loads the saved environments, or an empty list if none exist.
  List<MalphasEnvironment> loadEnvironments() {
    try {
      final file = _stateFile('environments');
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
  void saveRegistryIds(List<String> packageIds) {
    final file = _stateFile('registry');
    file.writeAsStringSync(jsonEncode(packageIds));
  }

  /// Loads the saved registry ids, or an empty list if none exist.
  List<String> loadRegistryIds() {
    try {
      final file = _stateFile('registry');
      if (!file.existsSync()) return [];
      final jsonList = jsonDecode(file.readAsStringSync()) as List<dynamic>;
      return jsonList.map((e) => e as String).toList();
    } catch (e) {
      return [];
    }
  }
}

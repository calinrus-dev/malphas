import 'dart:io';
import 'package:path/path.dart' as p;

/// Desktop-specific sandbox for native library loading.
///
/// Windows:  %LOCALAPPDATA%\Malphas\motors\
/// macOS:    ~/Library/Application Support/malphas/motors/
/// Linux:    ~/.local/share/malphas/motors/
class DesktopPathService {
  static String? _motorsDir;

  /// Returns the canonical sandboxed motors directory for this platform.
  static Future<String> motorsDirectory() async {
    if (_motorsDir != null) return _motorsDir!;
    _motorsDir = motorsDirectorySync();
    return _motorsDir!;
  }

  /// Synchronous variant used by the FFI binding during construction.
  static String motorsDirectorySync() {
    if (_motorsDir != null) return _motorsDir!;
    final base = _baseDirectorySync();
    return p.canonicalize(p.join(base, 'Malphas', 'motors'));
  }

  /// Resolves the expected path of a native motor inside the sandbox.
  static String motorPathSync(String name) {
    final dir = motorsDirectorySync();
    return p.canonicalize(p.join(dir, name));
  }

  /// Returns a validated motor path, or `null` if the file does not exist or
  /// is a symlink.
  static String? validatedMotorPathSync(String name) {
    final path = motorPathSync(name);
    final file = File(path);
    if (!file.existsSync()) return null;
    if (FileSystemEntity.isLinkSync(path)) return null;
    return p.canonicalize(path);
  }

  static String _baseDirectorySync() {
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return localAppData;
      }
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) return appData;
    }

    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      if (Platform.isMacOS) {
        return p.join(home, 'Library', 'Application Support');
      }
      if (Platform.isLinux) {
        return p.join(home, '.local', 'share');
      }
    }

    return '';
  }

  /// Test hook.
  static void setMotorsDirectoryForTests(String path) {
    _motorsDir = p.canonicalize(path);
  }

  /// Clears the test override.
  static void clearMotorsDirectoryForTests() {
    _motorsDir = null;
  }
}

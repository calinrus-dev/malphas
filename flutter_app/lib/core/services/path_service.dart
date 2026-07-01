import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Thrown when a path violates the application sandbox policy.
class PathSandboxException implements Exception {
  final String path;
  final String reason;

  const PathSandboxException(this.path, this.reason);

  @override
  String toString() => 'PathSandboxException: $path -> $reason';
}

/// Application-path sandbox service.
///
/// All filesystem paths used by the engine or UI must pass through
/// [canonicalizeAndValidate]. The service rejects traversal attempts, symlinks,
/// system directories, and any path that falls outside the application
/// documents directory root.
class PathService {
  static String? _documentsRoot;

  /// Initializes the sandbox root from [path_provider].
  static Future<void> initialize() async {
    final dir = await getApplicationDocumentsDirectory();
    _documentsRoot = p.canonicalize(dir.path);
  }

  /// Internal test hook to set the sandbox root without [path_provider].
  static void setDocumentsRootForTests(String root) {
    _documentsRoot = p.canonicalize(root);
  }

  /// Clears the test sandbox root.
  static void clearDocumentsRootForTests() {
    _documentsRoot = null;
  }

  /// Returns the canonicalized absolute path if [inputPath] is inside the
  /// application sandbox, otherwise throws [PathSandboxException].
  ///
  /// Validation rules:
  /// 1. Path must not contain `..` or `~` segments.
  /// 2. Path must not start with blocked system prefixes.
  /// 3. Path must not be a symlink.
  /// 4. Final canonical path must be under the app documents directory.
  static String canonicalizeAndValidate(String inputPath) {
    if (inputPath.isEmpty) {
      throw const PathSandboxException('', 'empty path');
    }

    final normalized = p.normalize(inputPath);
    final parts = p.split(normalized);

    if (parts.contains('..')) {
      throw PathSandboxException(inputPath, 'path traversal (..) detected');
    }
    if (parts.contains('~')) {
      throw PathSandboxException(inputPath, 'home shortcut (~) detected');
    }

    final absolute = p.isAbsolute(normalized)
        ? normalized
        : p.join(_documentsRoot ?? '', normalized);
    final canonical = p.canonicalize(absolute);

    if (_isBlockedPrefix(canonical)) {
      throw PathSandboxException(inputPath, 'blocked system path prefix');
    }

    final link = File(canonical);
    if (link.existsSync()) {
      try {
        if (FileSystemEntity.isLinkSync(canonical)) {
          throw PathSandboxException(inputPath, 'symlinks are not allowed');
        }
      } on FileSystemException {
        // If the platform cannot determine link status, treat it as a
        // rejection to stay conservative.
        throw PathSandboxException(inputPath, 'unable to verify path type');
      }
    }

    final root = _documentsRoot;
    if (root == null || root.isEmpty) {
      throw PathSandboxException(inputPath, 'sandbox root not initialized');
    }

    if (!canonical.startsWith(root)) {
      throw PathSandboxException(
          inputPath, 'path escapes app documents directory');
    }

    return canonical;
  }

  static bool _isBlockedPrefix(String canonical) {
    final lower = canonical.toLowerCase();
    final blocked = <String>{
      '/system',
      '/proc',
      '/data/data',
      r'c:\windows\system32',
      r'c:/windows/system32',
    };
    for (final prefix in blocked) {
      if (lower.startsWith(prefix)) return true;
    }
    return false;
  }
}

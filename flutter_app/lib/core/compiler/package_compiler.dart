import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Output of a `malphas-cli compile` invocation.
///
/// In v2.9.0 the CLI only produces the `.msp` Silver Platter.  The `.mxc`
/// system library is a Rust `cdylib` built separately by Cargo.
class CompileOutput {
  final Uint8List mspBytes;
  CompileOutput(this.mspBytes);
}

/// Compiles a Malphas package manifest by delegating to the native
/// `malphas-cli` executable.
class MalphasPackageCompiler {
  static const String _exeName = 'malphas-cli';
  static const String _fontFileName = 'JetBrainsMono-Regular.ttf';

  /// Compiles a Malphas package manifest by delegating to the native
  /// `malphas-cli` executable.
  ///
  /// If [sourceDir] is provided, it is used as the compilation working
  /// directory and must already contain a `manifest.json` file.  This allows
  /// callers to place payload `.bin` files next to the manifest before the
  /// compiler runs.  When [sourceDir] is omitted a fresh temporary directory is
  /// created and deleted automatically.
  Future<CompileOutput> compilePackage(
    Map<String, dynamic> manifest, {
    Directory? sourceDir,
  }) async {
    final packId = manifest['pack_id'] as String? ?? 'pack_custom_01';

    // 1. Prepare the working directory and write the manifest JSON next to it.
    final tempDir =
        sourceDir ?? await Directory.systemTemp.createTemp('malphas_compile_');
    final manifestFile = File('${tempDir.path}/manifest.json');
    if (sourceDir == null) {
      await manifestFile.writeAsString(jsonEncode(manifest));
    }

    // The CLI expects JetBrainsMono-Regular.ttf next to the manifest.
    final fontFile = _resolveFontFile();
    if (fontFile != null) {
      await fontFile.copy('${tempDir.path}/$_fontFileName');
    }

    // 2. Locate the native CLI executable.
    final exePath = await _resolveCliExecutable();
    if (exePath == null) {
      if (sourceDir == null) await _bestEffortDelete(tempDir);
      throw Exception('malphas-cli executable not found');
    }

    // 3. Invoke the CLI with a defensive timeout and capture both stdout and
    // stderr so failures can be diagnosed without leaking temp directories.
    final result = await Process.run(
      exePath,
      ['compile', manifestFile.path],
      runInShell: false,
    ).timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        throw Exception('malphas-cli compile timed out after 2 minutes');
      },
    );
    if (result.exitCode != 0) {
      if (sourceDir == null) await _bestEffortDelete(tempDir);
      throw Exception(
        'malphas-cli compile failed (exit ${result.exitCode}): '
        'stderr=${result.stderr}, stdout=${result.stdout}',
      );
    }

    // 4. Read the generated .msp file.
    final mspFile = File('${tempDir.path}/$packId.msp');
    if (!await mspFile.exists()) {
      if (sourceDir == null) await _bestEffortDelete(tempDir);
      throw Exception('Expected compiled package not found: ${mspFile.path}');
    }
    final mspBytes = await mspFile.readAsBytes();

    // 5. Clean up the temporary manifest and generated binaries only if we
    // created the directory ourselves.
    if (sourceDir == null) {
      await _bestEffortDelete(tempDir);
    }

    return CompileOutput(mspBytes);
  }

  /// Returns `true` if the native CLI executable can be located.
  Future<bool> isCliAvailable() async => await _resolveCliExecutable() != null;

  /// Resolves the path to the `malphas-cli` executable using the search order:
  ///   1. flutter_app/motors/malphas-cli (or .exe on Windows)
  ///   2. target/release/malphas-cli (or .exe)
  ///   3. malphas_cli/target/release/malphas-cli (or .exe)
  ///   4. System PATH (which / where)
  Future<String?> _resolveCliExecutable() async {
    final exeName = _platformExeName(_exeName);
    final workspaceRoot = _findWorkspaceRoot();

    final candidates = <String>[
      if (workspaceRoot != null)
        _join(workspaceRoot, 'flutter_app', 'motors', exeName),
      if (workspaceRoot != null)
        _join(workspaceRoot, 'target', 'release', exeName),
      if (workspaceRoot != null)
        _join(workspaceRoot, 'malphas_cli', 'target', 'release', exeName),
    ];

    for (final candidate in candidates) {
      if (await File(candidate).exists() && await _isExecutable(candidate)) {
        return candidate;
      }
    }

    // 4. Fall back to the system PATH.
    return _findInPath(exeName);
  }

  /// Returns `true` if [path] can be executed on this platform. On Windows
  /// existence is sufficient; on Unix at least one execute bit must be set.
  Future<bool> _isExecutable(String path) async {
    if (Platform.isWindows) return true;
    try {
      final stat = await File(path).stat();
      return stat.mode & 0x49 != 0;
    } catch (_) {
      return false;
    }
  }

  /// Walks up from the current working directory looking for a workspace
  /// root (a directory containing `Cargo.toml` with `[workspace]`).
  String? _findWorkspaceRoot() {
    var current = Directory.current;
    for (var i = 0; i < 8; i++) {
      final cargoToml = File(_join(current.path, 'Cargo.toml'));
      if (cargoToml.existsSync()) {
        try {
          final contents = cargoToml.readAsStringSync();
          if (contents.contains('[workspace]')) {
            return current.path;
          }
        } catch (_) {}
      }
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
    return null;
  }

  /// Locates the JetBrains Mono font file that the CLI uses to build the
  /// font atlas. It is expected under `flutter_app/assets/fonts/` relative to
  /// the workspace root.
  File? _resolveFontFile() {
    final workspaceRoot = _findWorkspaceRoot();
    if (workspaceRoot != null) {
      final candidate = File(
        _join(workspaceRoot, 'flutter_app', 'assets', 'fonts', _fontFileName),
      );
      if (candidate.existsSync()) return candidate;
    }

    var current = Directory.current;
    for (var i = 0; i < 8; i++) {
      final candidate =
          File(_join(current.path, 'assets', 'fonts', _fontFileName));
      if (candidate.existsSync()) return candidate;
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
    return null;
  }

  /// Returns the executable name including `.exe` on Windows.
  String _platformExeName(String name) {
    if (Platform.isWindows) return '$name.exe';
    return name;
  }

  /// Joins path segments using the platform separator.
  String _join(
    String first,
    String second, [
    String? third,
    String? fourth,
    String? fifth,
  ]) {
    var path = first;
    for (final part in [second, third, fourth, fifth]) {
      if (part == null) continue;
      path = '$path${Platform.pathSeparator}$part';
    }
    return path;
  }

  /// Looks for an executable in the system PATH.
  Future<String?> _findInPath(String name) async {
    final which = Platform.isWindows ? 'where' : 'which';
    try {
      final result = await Process.run(which, [name], runInShell: true);
      if (result.exitCode == 0) {
        final found = result.stdout.toString().split('\n').first.trim();
        if (found.isNotEmpty &&
            await File(found).exists() &&
            await _isExecutable(found)) {
          return found;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _bestEffortDelete(FileSystemEntity entity) async {
    try {
      await entity.delete(recursive: entity is Directory);
    } catch (_) {}
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import 'package_controller.dart';

class PackageConfigScreen extends StatefulWidget {
  const PackageConfigScreen({super.key});

  @override
  State<PackageConfigScreen> createState() => _PackageConfigScreenState();
}

class _PackageConfigScreenState extends State<PackageConfigScreen> {
  final PackageController _controller = PackageController();
  final _pathController = TextEditingController();

  int _mhpCount = 0;
  int _mspCount = 0;
  List<String> _foundFiles = [];
  bool _dirExists = false;

  @override
  void initState() {
    super.initState();
    final currentPath = _controller.resolveWorkspaceRoot();
    _pathController.text = currentPath;
    _scanDirectory(currentPath);
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  void _scanDirectory(String path) {
    if (path.trim().isEmpty) {
      setState(() {
        _mhpCount = 0;
        _mspCount = 0;
        _foundFiles = [];
        _dirExists = false;
      });
      return;
    }

    try {
      final dir = Directory(path.trim());
      if (dir.existsSync()) {
        final List<String> names = [];
        int mhp = 0;
        int msp = 0;

        // Scan direct children (packages/ and subfolders if needed)
        // Check for MHP/MSP files inside packages/ directory or root directory
        final targets = [dir, Directory('${dir.path}/packages')];
        for (final targetDir in targets) {
          if (targetDir.existsSync()) {
            for (final entity in targetDir.listSync()) {
              if (entity is File) {
                final name = entity.uri.pathSegments.last;
                if (name.toLowerCase().endsWith('.mhp')) {
                  mhp++;
                  names.add(name);
                } else if (name.toLowerCase().endsWith('.msp')) {
                  msp++;
                  names.add(name);
                }
              }
            }
          }
        }

        setState(() {
          _mhpCount = mhp;
          _mspCount = msp;
          _foundFiles = names;
          _dirExists = true;
        });
      } else {
        setState(() {
          _mhpCount = 0;
          _mspCount = 0;
          _foundFiles = [];
          _dirExists = false;
        });
      }
    } catch (_) {
      setState(() {
        _mhpCount = 0;
        _mspCount = 0;
        _foundFiles = [];
        _dirExists = false;
      });
    }
  }

  Future<void> _applyWorkspacePath() async {
    final newPath = _pathController.text.trim();
    if (newPath.isEmpty) return;

    try {
      final dir = Directory(newPath);
      if (!dir.existsSync()) {
        // Attempt to create it if it doesn't exist (if parent directory is writable)
        dir.createSync(recursive: true);
      }

      await _controller.updateWorkspaceRoot(newPath);
      _scanDirectory(newPath);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xff0d0d0d),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xff00ffcc)),
            ),
            content: const Text(
              'Workspace path applied successfully!',
              style: TextStyle(
                  fontFamily: 'Courier',
                  color: Color(0xff00ffcc),
                  fontSize: 11),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xff0d0d0d),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xffd32f2f)),
            ),
            content: Text(
              'Failed to apply workspace path: $e',
              style: const TextStyle(
                  fontFamily: 'Courier',
                  color: Color(0xffe0dcd3),
                  fontSize: 11),
            ),
          ),
        );
      }
    }
  }

  Future<void> _resetToDefault() async {
    try {
      await _controller.updateWorkspaceRoot(null);
      final defaultPath = _controller.resolveWorkspaceRoot();
      _pathController.text = defaultPath;
      _scanDirectory(defaultPath);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xff0d0d0d),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xff00ffcc)),
            ),
            content: const Text(
              'Workspace path reset to default!',
              style: TextStyle(
                  fontFamily: 'Courier',
                  color: Color(0xff00ffcc),
                  fontSize: 11),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xff0d0d0d),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xffd32f2f)),
            ),
            content: Text(
              'Error resetting path: $e',
              style: const TextStyle(
                  fontFamily: 'Courier',
                  color: Color(0xffe0dcd3),
                  fontSize: 11),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff000000),
      appBar: AppBar(
        title: const Text(
          'WORKSPACE SETTINGS',
          style: TextStyle(
            fontFamily: 'Georgia',
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: Color(0xffe0dcd3),
          ),
        ),
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios,
              size: 14, color: Color(0xffe0dcd3)),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'MALPHAS SYSTEM DIRECTORY',
                style: TextStyle(
                  fontFamily: 'Courier',
                  fontSize: 10,
                  color: Color(0xff00ffcc),
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xff0d0d0d),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xff1b1b1b)),
                ),
                child: TextFormField(
                  controller: _pathController,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13, fontFamily: 'Arial'),
                  decoration: const InputDecoration(
                    labelText: 'Workspace Root Folder Path',
                    labelStyle: TextStyle(color: Colors.white38, fontSize: 11),
                    border: InputBorder.none,
                  ),
                  onChanged: _scanDirectory,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xff0d0d0d),
                          side: const BorderSide(color: Color(0xff1b1b1b)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24)),
                        ),
                        onPressed: _resetToDefault,
                        child: const Text(
                          'RESET TO DEFAULT',
                          style: TextStyle(
                            fontFamily: 'Courier',
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xff00ffcc),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24)),
                        ),
                        onPressed: _applyWorkspacePath,
                        child: const Text(
                          'APPLY PATH',
                          style: TextStyle(
                            fontFamily: 'Courier',
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(color: Color(0xff1b1b1b), height: 40),
              const Text(
                'WORKSPACE STATUS TELEMETRY',
                style: TextStyle(
                  fontFamily: 'Courier',
                  fontSize: 10,
                  color: Colors.white38,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xff0d0d0d),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xff1b1b1b)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Directory Verified: ',
                          style: TextStyle(
                              fontFamily: 'Courier',
                              color: Colors.white70,
                              fontSize: 11),
                        ),
                        Text(
                          _dirExists ? 'YES (ACTIVE)' : 'NO (NOT FOUND)',
                          style: TextStyle(
                            fontFamily: 'Courier',
                            color: _dirExists
                                ? const Color(0xff00ffcc)
                                : Colors.redAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'MHP Packages Found: $_mhpCount',
                      style: const TextStyle(
                          fontFamily: 'Courier',
                          color: Colors.white70,
                          fontSize: 11),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'MSP Bytecode Scripts Found: $_mspCount',
                      style: const TextStyle(
                          fontFamily: 'Courier',
                          color: Colors.white70,
                          fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'FOUND BINARIES IN DIRECTORY',
                style: TextStyle(
                  fontFamily: 'Courier',
                  fontSize: 10,
                  color: Colors.white38,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              if (_foundFiles.isEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 30),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xff0d0d0d),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xff161616)),
                  ),
                  child: const Text(
                    'No .mhp or .msp files detected in this folder.',
                    style: TextStyle(
                        color: Colors.white24,
                        fontSize: 11,
                        fontFamily: 'Arial'),
                  ),
                )
              else
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _foundFiles.length,
                  itemBuilder: (context, index) {
                    final filename = _foundFiles[index];
                    final isMsp = filename.toLowerCase().endsWith('.msp');
                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xff0d0d0d),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xff1b1b1b)),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isMsp
                                ? Icons.analytics_outlined
                                : Icons.folder_zip_outlined,
                            size: 14,
                            color: isMsp
                                ? const Color(0xff00ffcc)
                                : Colors.white30,
                          ),
                          const SizedBox(width: 12),
                          Text(
                            filename,
                            style: const TextStyle(
                              fontFamily: 'Courier',
                              fontSize: 12,
                              color: Color(0xffe0dcd3),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

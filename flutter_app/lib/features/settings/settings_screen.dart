import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/services/app_state_persistence_service.dart';
import '../../core/services/telemetry_service.dart';
import '../../core/services/user_workspace_directory_service.dart';
import '../../core/theme/theme.dart';
import '../../core/ui_primitives/malphas_widgets.dart';
import '../package_manager/package_controller.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final UserWorkspaceDirectoryService _workspaceService =
      UserWorkspaceDirectoryService();
  final PackageController _packageController = PackageController();
  final AppStatePersistenceService _persistence = AppStatePersistenceService();
  final TelemetryService _telemetry = TelemetryService();

  String _currentPath = '';
  String _defaultPath = '';
  bool _isLoading = true;
  bool _telemetryOverlayEnabled = false;
  bool _telemetryGpsEnabled = false;

  @override
  void initState() {
    super.initState();
    _loadCurrentPath();
  }

  Future<void> _loadCurrentPath() async {
    final current = await _workspaceService.resolveUserWorkspaceRoot();
    final docs = await getApplicationDocumentsDirectory();
    final overlayEnabled = await _persistence.loadTelemetryOverlayEnabled();
    final gpsEnabled = await _persistence.loadTelemetryGpsEnabled();
    setState(() {
      _currentPath = current;
      _defaultPath = '${docs.path}${Platform.pathSeparator}Malphas';
      _telemetryOverlayEnabled = overlayEnabled;
      _telemetryGpsEnabled = gpsEnabled;
      _isLoading = false;
    });
  }

  Future<void> _pickDirectory() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select Malphas user workspace directory',
      );
      if (result == null || result.isEmpty) return;
      setState(() => _currentPath = result);
      await _applyPath(result);
    } catch (e) {
      _showSnackBar('Error selecting directory: $e', isError: true);
    }
  }

  Future<void> _applyPath(String path) async {
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      await _packageController.updateWorkspaceRoot(path);
      await _loadCurrentPath();
      if (mounted) {
        _showSnackBar('User workspace directory updated successfully!');
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('Failed to update workspace directory: $e',
            isError: true);
      }
    }
  }

  Future<void> _resetToDefault() async {
    try {
      await _packageController.updateWorkspaceRoot(null);
      await _loadCurrentPath();
      if (mounted) {
        _showSnackBar('Reset to default workspace directory.');
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('Error resetting directory: $e', isError: true);
      }
    }
  }

  Future<void> _setTelemetryOverlayEnabled(bool enabled) async {
    await _persistence.saveTelemetryOverlayEnabled(enabled);
    setState(() => _telemetryOverlayEnabled = enabled);
  }

  Future<void> _setTelemetryGpsEnabled(bool enabled) async {
    if (enabled) {
      final ok = await _telemetry.setGpsEnabled(true);
      if (!ok) {
        if (mounted) {
          _showSnackBar(
            'GPS permission denied or location services disabled.',
            isError: true,
          );
        }
        return;
      }
    } else {
      await _telemetry.setGpsEnabled(false);
    }
    await _persistence.saveTelemetryGpsEnabled(enabled);
    setState(() => _telemetryGpsEnabled = enabled);
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: MalphasTheme.slate,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: isError ? Colors.redAccent : MalphasTheme.accent,
          ),
        ),
        content: Text(
          message,
          style: TextStyle(
            fontFamily: 'Courier',
            color: isError ? MalphasTheme.bone : MalphasTheme.accent,
            fontSize: 11,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MalphasTheme.ink,
      appBar: AppBar(
        backgroundColor: MalphasTheme.ink,
        elevation: 0,
        leading: MalphasIconButton(
          icon: Icons.arrow_back_ios,
          tooltip: 'Back to hub',
          size: 14,
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'GENERAL SETTINGS',
          style: TextStyle(
            fontFamily: 'Georgia',
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: MalphasTheme.bone,
          ),
        ),
      ),
      body: SafeArea(
        child: _isLoading
            ? const MalphasLoadingIndicator(message: 'LOADING SETTINGS')
            : SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSectionHeader('USER WORKSPACE DIRECTORY'),
                    const SizedBox(height: 8),
                    _buildSectionBody(
                      'This is where your packages, systems and environment data are stored. It works across Android, Linux, macOS and Windows.',
                    ),
                    const SizedBox(height: 16),
                    MalphasCard(
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _currentPath,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontFamily: 'Arial',
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
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
                                backgroundColor: MalphasTheme.slate,
                                side: const BorderSide(
                                    color: MalphasTheme.borderAccent),
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
                                backgroundColor: MalphasTheme.accent,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24)),
                              ),
                              onPressed: _pickDirectory,
                              child: const Text(
                                'CHANGE FOLDER',
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
                    const SizedBox(height: 24),
                    MalphasCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'DEFAULT LOCATION',
                            style: TextStyle(
                              fontFamily: 'Courier',
                              fontSize: 10,
                              color: Colors.white38,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _defaultPath,
                            style: const TextStyle(
                              fontFamily: 'Arial',
                              fontSize: 11,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    _buildSectionHeader('RUNTIME TELEMETRY'),
                    const SizedBox(height: 8),
                    _buildSectionBody(
                      'Show a memory and timing overlay on the workspace screen. GPS telemetry is optional and only collected when explicitly enabled.',
                    ),
                    const SizedBox(height: 16),
                    _buildTelemetryTile(
                      label: 'TELEMETRY OVERLAY',
                      description:
                          'Display RAM, MSP build time and engine timing on the workspace.',
                      value: _telemetryOverlayEnabled,
                      onChanged: _setTelemetryOverlayEnabled,
                    ),
                    const SizedBox(height: 12),
                    _buildTelemetryTile(
                      label: 'GPS TELEMETRY',
                      description:
                          'Attach location coordinates to telemetry snapshots. Requires location permission.',
                      value: _telemetryGpsEnabled,
                      onChanged: _setTelemetryGpsEnabled,
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildSectionHeader(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'Courier',
        fontSize: 10,
        color: MalphasTheme.accent,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildSectionBody(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontFamily: 'Arial',
        fontSize: 11,
        color: Colors.white38,
        height: 1.4,
      ),
    );
  }

  Widget _buildTelemetryTile({
    required String label,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return MalphasCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontFamily: 'Courier',
                    fontSize: 10,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    fontFamily: 'Arial',
                    fontSize: 10,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
          Semantics(
            label: '$label toggle',
            toggled: value,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeColor: MalphasTheme.accent,
            ),
          ),
        ],
      ),
    );
  }
}

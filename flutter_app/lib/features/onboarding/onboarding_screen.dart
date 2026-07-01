import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/services/app_state_persistence_service.dart';
import '../../core/services/user_workspace_directory_service.dart';
import '../../core/theme/theme.dart';
import '../../core/ui_primitives/malphas_widgets.dart';
import '../hub/hub_screen.dart';

/// First-run onboarding flow.
///
/// Walks the user through workspace directory selection and trust-anchor
/// guidance, then marks onboarding as completed and navigates to the hub.
class MalphasOnboardingScreen extends StatefulWidget {
  const MalphasOnboardingScreen({super.key});

  @override
  State<MalphasOnboardingScreen> createState() =>
      _MalphasOnboardingScreenState();
}

class _MalphasOnboardingScreenState extends State<MalphasOnboardingScreen> {
  final PageController _pageController = PageController();
  final AppStatePersistenceService _persistence = AppStatePersistenceService();
  final UserWorkspaceDirectoryService _workspaceService =
      UserWorkspaceDirectoryService();

  String _workspacePath = '';
  bool _isPickingDirectory = false;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _loadDefaultWorkspacePath();
  }

  Future<void> _loadDefaultWorkspacePath() async {
    final path = await _workspaceService.resolveUserWorkspaceRoot();
    setState(() => _workspacePath = path);
  }

  Future<void> _pickDirectory() async {
    setState(() => _isPickingDirectory = true);
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select your Malphas workspace directory',
      );
      if (result != null && result.isNotEmpty) {
        final dir = Directory(result);
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        await _workspaceService.setUserWorkspaceDirectory(result);
        setState(() => _workspacePath = result);
      }
    } catch (e) {
      _showError('Could not select directory: $e');
    } finally {
      setState(() => _isPickingDirectory = false);
    }
  }

  Future<void> _completeOnboarding() async {
    await _persistence.saveOnboardingCompleted();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (context, anim, secondaryAnim) =>
              const MalphasHubScreen(),
          transitionsBuilder: (context, anim, secondaryAnim, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 600),
        ),
      );
    }
  }

  void _nextPage() {
    if (_currentPage < 2) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    } else {
      _completeOnboarding();
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: MalphasTheme.slate,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Colors.redAccent),
        ),
        content: Text(
          message,
          style: const TextStyle(
            fontFamily: 'Courier',
            color: Colors.redAccent,
            fontSize: 11,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MalphasTheme.ink,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (index) => setState(() => _currentPage = index),
                children: [
                  _buildWelcomePage(),
                  _buildWorkspacePage(),
                  _buildTrustAnchorPage(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(
                children: [
                  _buildDot(0),
                  const SizedBox(width: 8),
                  _buildDot(1),
                  const SizedBox(width: 8),
                  _buildDot(2),
                  const Spacer(),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: MalphasTheme.accent,
                      foregroundColor: MalphasTheme.ink,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 14,
                      ),
                    ),
                    onPressed: _nextPage,
                    child: Text(
                      _currentPage == 2 ? 'ENTER MALPHAS' : 'NEXT',
                      style: const TextStyle(
                        fontFamily: 'Courier',
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcomePage() {
    return const Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.layers_outlined,
            size: 72,
            color: MalphasTheme.accent,
          ),
          SizedBox(height: 32),
          Text(
            'SOVEREIGN RUNTIME',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Georgia',
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: MalphasTheme.bone,
              letterSpacing: 2,
            ),
          ),
          SizedBox(height: 16),
          Text(
            'Malphas turns every Environment into a self-contained mini operating system: packages, native logic cores, assets, and telemetry under your control.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Arial',
              fontSize: 13,
              color: MalphasTheme.mist,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWorkspacePage() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.folder_open_outlined,
            size: 64,
            color: MalphasTheme.accent,
          ),
          const SizedBox(height: 32),
          const Text(
            'CHOOSE YOUR WORKSPACE',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Georgia',
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: MalphasTheme.bone,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'This directory stores your packages, systems and environment data. It can be changed later in Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Arial',
              fontSize: 12,
              color: MalphasTheme.mist,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 32),
          MalphasCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _workspacePath.isEmpty ? 'Default location' : 'SELECTED PATH',
                  style: const TextStyle(
                    fontFamily: 'Courier',
                    fontSize: 9,
                    color: MalphasTheme.mist,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _workspacePath.isEmpty ? 'Resolving...' : _workspacePath,
                  style: const TextStyle(
                    fontFamily: 'Arial',
                    fontSize: 12,
                    color: MalphasTheme.bone,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: MalphasTheme.slate,
                foregroundColor: MalphasTheme.bone,
                side: const BorderSide(color: MalphasTheme.borderAccent),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
              onPressed: _isPickingDirectory ? null : _pickDirectory,
              child: _isPickingDirectory
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: MalphasTheme.bone,
                      ),
                    )
                  : const Text(
                      'CHANGE FOLDER',
                      style: TextStyle(
                        fontFamily: 'Courier',
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrustAnchorPage() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.verified_user_outlined,
            size: 64,
            color: MalphasTheme.accent,
          ),
          const SizedBox(height: 32),
          const Text(
            'TRUST ANCHOR',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Georgia',
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: MalphasTheme.bone,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Malphas verifies every native core, package and system with Ed25519 signatures. In production you will import or generate a trust anchor in Settings.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Arial',
              fontSize: 12,
              color: MalphasTheme.mist,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 32),
          MalphasCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTrustBullet('Signed MSP packages'),
                _buildTrustBullet('Signed MXC logic cores'),
                _buildTrustBullet('Sandboxed file access'),
                _buildTrustBullet('Optional telemetry (off by default)'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrustBullet(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline,
              size: 16, color: MalphasTheme.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: 'Arial',
                fontSize: 12,
                color: MalphasTheme.bone,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDot(int index) {
    final active = index == _currentPage;
    return Container(
      width: active ? 20 : 8,
      height: 8,
      decoration: BoxDecoration(
        color: active ? MalphasTheme.accent : MalphasTheme.borderAccent,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}

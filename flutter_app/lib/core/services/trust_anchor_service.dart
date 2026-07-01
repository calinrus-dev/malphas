import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure storage for the Ed25519 trust anchor used by the native engine.
///
/// The public key is stored in the platform keyring/keystore:
/// - Android: Android Keystore via flutter_secure_storage
/// - iOS: Keychain via flutter_secure_storage
/// - Desktop: OS keyring/credential store via flutter_secure_storage
class TrustAnchorService {
  static const _storage = FlutterSecureStorage();
  static const _key = 'malphas_trust_anchor_public_key';

  /// Stores the Ed25519 public key (hex, no whitespace).
  static Future<void> store(String publicKeyHex) async {
    final cleaned = publicKeyHex.replaceAll(RegExp(r'\s+'), '');
    await _storage.write(key: _key, value: cleaned);
  }

  /// Retrieves the stored Ed25519 public key, or `null` if none exists.
  static Future<String?> retrieve() async {
    final value = await _storage.read(key: _key);
    if (value == null || value.isEmpty) return null;
    return value.replaceAll(RegExp(r'\s+'), '');
  }

  /// Deletes the stored trust anchor.
  static Future<void> delete() async {
    await _storage.delete(key: _key);
  }

  /// Returns `true` if a trust anchor is configured.
  static Future<bool> hasAnchor() async {
    final value = await _storage.read(key: _key);
    return value != null && value.isNotEmpty;
  }
}

/// Runtime policy enforced by an environment before launching a system.
///
/// Environments act as a mini OS: each channel declares what the attached
/// systems are allowed to do.  The engine is responsible for applying the
/// policy; this model is the UI-side contract.
class EnvironmentPolicy {
  /// If true, the environment refuses any write operation to the workspace.
  final bool readOnly;

  /// If true, systems may read from the broader filesystem outside the
  /// user workspace (e.g. absolute asset paths).
  final bool allowFilesystemAccess;

  /// If true, the environment permits outbound network requests.
  final bool allowNetwork;

  /// If true, audio playback is allowed.
  final bool allowAudio;

  /// If true, location/GPS telemetry may be collected.
  final bool allowLocationTelemetry;

  /// Maximum RAM in bytes the environment may allocate for its systems.
  /// A value of zero means unlimited.
  final int maxRamBytes;

  /// Allowed file extensions for asset payloads.
  final List<String> allowedAssetExtensions;

  /// Optional list of allowed absolute or workspace-relative paths.
  final List<String> allowedSystemPaths;

  const EnvironmentPolicy({
    this.readOnly = false,
    this.allowFilesystemAccess = false,
    this.allowNetwork = false,
    this.allowAudio = true,
    this.allowLocationTelemetry = false,
    this.maxRamBytes = 0,
    this.allowedAssetExtensions = const [
      '.png',
      '.jpg',
      '.jpeg',
      '.wav',
      '.mp3',
      '.ogg',
      '.json'
    ],
    this.allowedSystemPaths = const [],
  });

  static const EnvironmentPolicy sandbox = EnvironmentPolicy(
    readOnly: true,
    allowFilesystemAccess: false,
    allowNetwork: false,
    allowAudio: true,
    allowLocationTelemetry: false,
    maxRamBytes: 64 * 1024 * 1024,
  );

  static const EnvironmentPolicy trusted = EnvironmentPolicy(
    readOnly: false,
    allowFilesystemAccess: true,
    allowNetwork: true,
    allowAudio: true,
    allowLocationTelemetry: true,
    maxRamBytes: 0,
  );

  Map<String, dynamic> toJson() => {
        'readOnly': readOnly,
        'allowFilesystemAccess': allowFilesystemAccess,
        'allowNetwork': allowNetwork,
        'allowAudio': allowAudio,
        'allowLocationTelemetry': allowLocationTelemetry,
        'maxRamBytes': maxRamBytes,
        'allowedAssetExtensions': allowedAssetExtensions,
        'allowedSystemPaths': allowedSystemPaths,
      };

  factory EnvironmentPolicy.fromJson(Map<String, dynamic> json) {
    return EnvironmentPolicy(
      readOnly: json['readOnly'] == true,
      allowFilesystemAccess: json['allowFilesystemAccess'] == true,
      allowNetwork: json['allowNetwork'] == true,
      allowAudio: json['allowAudio'] != false,
      allowLocationTelemetry: json['allowLocationTelemetry'] == true,
      maxRamBytes: json['maxRamBytes'] is int ? json['maxRamBytes'] as int : 0,
      allowedAssetExtensions: json['allowedAssetExtensions'] is List
          ? (json['allowedAssetExtensions'] as List)
              .whereType<String>()
              .toList()
          : const ['.png', '.jpg', '.jpeg', '.wav', '.mp3', '.ogg', '.json'],
      allowedSystemPaths: json['allowedSystemPaths'] is List
          ? (json['allowedSystemPaths'] as List).whereType<String>().toList()
          : const [],
    );
  }

  EnvironmentPolicy copyWith({
    bool? readOnly,
    bool? allowFilesystemAccess,
    bool? allowNetwork,
    bool? allowAudio,
    bool? allowLocationTelemetry,
    int? maxRamBytes,
    List<String>? allowedAssetExtensions,
    List<String>? allowedSystemPaths,
  }) {
    return EnvironmentPolicy(
      readOnly: readOnly ?? this.readOnly,
      allowFilesystemAccess:
          allowFilesystemAccess ?? this.allowFilesystemAccess,
      allowNetwork: allowNetwork ?? this.allowNetwork,
      allowAudio: allowAudio ?? this.allowAudio,
      allowLocationTelemetry:
          allowLocationTelemetry ?? this.allowLocationTelemetry,
      maxRamBytes: maxRamBytes ?? this.maxRamBytes,
      allowedAssetExtensions:
          allowedAssetExtensions ?? this.allowedAssetExtensions,
      allowedSystemPaths: allowedSystemPaths ?? this.allowedSystemPaths,
    );
  }
}

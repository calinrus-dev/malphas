import 'package:flutter/material.dart';

/// A persistent Malphas operational environment.
///
/// Environments are saved to disk as JSON by [AppStatePersistenceService] and
/// restored on the next app launch.
class MalphasEnvironment {
  final String id;
  String name;
  Color accentColor;
  bool isPinned;
  String? engineId;
  List<String> packageIds;

  MalphasEnvironment({
    required this.id,
    required this.name,
    required this.accentColor,
    this.isPinned = false,
    this.engineId,
    this.packageIds = const [],
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'accentColor': accentColor.toARGB32(),
        'isPinned': isPinned,
        'engineId': engineId,
        'packageIds': packageIds,
      };

  factory MalphasEnvironment.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'];
    final rawName = json['name'];
    final rawAccentColor = json['accentColor'];
    final rawIsPinned = json['isPinned'];
    final rawEngineId = json['engineId'];
    final rawPackageIds = json['packageIds'];

    int? parsedColor;
    if (rawAccentColor is int) {
      parsedColor = rawAccentColor;
    } else if (rawAccentColor is String) {
      parsedColor = int.tryParse(rawAccentColor);
    }

    List<String> parsedPackageIds;
    if (rawPackageIds is List) {
      parsedPackageIds = rawPackageIds.whereType<String>().toList();
    } else {
      parsedPackageIds = [];
    }

    return MalphasEnvironment(
      id: rawId is String
          ? rawId
          : 'env_${DateTime.now().millisecondsSinceEpoch}',
      name: rawName is String ? rawName : 'Unnamed Environment',
      accentColor:
          parsedColor != null ? Color(parsedColor) : const Color(0xffe0dcd3),
      isPinned: rawIsPinned is bool
          ? rawIsPinned
          : (rawIsPinned?.toString().toLowerCase() == 'true'),
      engineId: rawEngineId is String ? rawEngineId : null,
      packageIds: parsedPackageIds,
    );
  }
}

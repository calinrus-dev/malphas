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

  factory MalphasEnvironment.fromJson(Map<String, dynamic> json) =>
      MalphasEnvironment(
        id: json['id'] as String,
        name: json['name'] as String,
        accentColor: Color(json['accentColor'] as int),
        isPinned: json['isPinned'] as bool? ?? false,
        engineId: json['engineId'] as String?,
        packageIds: (json['packageIds'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            const [],
      );
}

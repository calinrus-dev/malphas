class MalphasTag {
  final String name;
  final bool isPublic; // true = Azul (pública, se muestra), false = Gris (interna, oculta)

  const MalphasTag({required this.name, required this.isPublic});

  Map<String, dynamic> toJson() => {
    'name': name,
    'isPublic': isPublic,
  };

  factory MalphasTag.fromJson(Map<String, dynamic> json) => MalphasTag(
    name: json['name'] as String,
    isPublic: json['isPublic'] as bool,
  );
}

class MalphasSkin {
  final String id;
  final String name;
  final String assetPath;
  final String version;

  const MalphasSkin({
    required this.id,
    required this.name,
    required this.assetPath,
    required this.version,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'assetPath': assetPath,
    'version': version,
  };

  factory MalphasSkin.fromJson(Map<String, dynamic> json) => MalphasSkin(
    id: json['id'] as String,
    name: json['name'] as String,
    assetPath: json['assetPath'] as String,
    version: json['version'] as String,
  );
}

class MalphasObject {
  String id;
  String name;
  String category;
  Map<String, String> properties;
  List<MalphasTag> tags;
  List<MalphasSkin> skins;
  int activeSkinIndex;

  MalphasObject({
    required this.id,
    required this.name,
    required this.category,
    required this.properties,
    required this.tags,
    required this.skins,
    this.activeSkinIndex = 0,
  });

  MalphasSkin get currentSkin => skins.isEmpty 
      ? const MalphasSkin(id: 'none', name: 'None', assetPath: 'none', version: '1.0')
      : skins[activeSkinIndex];

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'category': category,
    'properties': properties,
    'tags': tags.map((t) => t.toJson()).toList(),
    'skins': skins.map((s) => s.toJson()).toList(),
    'activeSkinIndex': activeSkinIndex,
  };

  factory MalphasObject.fromJson(Map<String, dynamic> json) => MalphasObject(
    id: json['id'] as String,
    name: json['name'] as String,
    category: json['category'] as String,
    properties: Map<String, String>.from(json['properties'] as Map),
    tags: (json['tags'] as List).map((t) => MalphasTag.fromJson(t as Map<String, dynamic>)).toList(),
    skins: (json['skins'] as List).map((s) => MalphasSkin.fromJson(s as Map<String, dynamic>)).toList(),
    activeSkinIndex: json['activeSkinIndex'] as int? ?? 0,
  );
}

class MalphasPackage {
  String id;
  String name;
  String version;
  String author;
  String description;
  String? coverImagePath; // Imagen de portada 1:1
  List<MalphasObject> objects;
  bool isLoaded;

  MalphasPackage({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    this.coverImagePath,
    required this.objects,
    this.isLoaded = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'version': version,
    'author': author,
    'description': description,
    'coverImagePath': coverImagePath,
    'objects': objects.map((o) => o.toJson()).toList(),
    'isLoaded': isLoaded,
  };

  factory MalphasPackage.fromJson(Map<String, dynamic> json) => MalphasPackage(
    id: json['id'] as String,
    name: json['name'] as String,
    version: json['version'] as String,
    author: json['author'] as String,
    description: json['description'] as String,
    coverImagePath: json['coverImagePath'] as String?,
    objects: (json['objects'] as List).map((o) => MalphasObject.fromJson(o as Map<String, dynamic>)).toList(),
    isLoaded: json['isLoaded'] as bool? ?? true,
  );
}

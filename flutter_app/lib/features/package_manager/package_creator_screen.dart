import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/ffi/malphas_bindings.dart';
import '../hub/environment_model.dart';
import '../../core/models/flat_models.dart';
import 'package_controller.dart';

class PackageCreatorScreen extends StatefulWidget {
  final MalphasEnvironment? activeEnvironment;
  const PackageCreatorScreen({super.key, this.activeEnvironment});

  @override
  State<PackageCreatorScreen> createState() => _PackageCreatorScreenState();
}

class _PackageCreatorScreenState extends State<PackageCreatorScreen> {
  final _formKey = GlobalKey<FormState>();
  final PackageController _controller = PackageController();

  final _packIdController = TextEditingController(text: 'custom_bouncing');
  final _nameController = TextEditingController(text: 'My Custom Package');
  final _versionController = TextEditingController(text: '1.0.0');
  final _authorController = TextEditingController(text: 'Calin Rus');
  final _descriptionController = TextEditingController(
    text: 'A modular, user-created bouncing objects pack.',
  );
  final _widthController = TextEditingController(text: '1000');
  final _heightController = TextEditingController(text: '1000');

  final List<Entity> _objects = [];
  final List<EntityPayload> _payloads = [];
  final List<EntityTag> _tags = [];
  final List<EntityProperty> _properties = [];
  bool _isCompiling = false;

  // Undo/redo history.
  final List<_EditorState> _undoStack = [];
  final List<_EditorState> _redoStack = [];
  static const int _maxHistoryDepth = 50;

  @override
  void dispose() {
    _packIdController.dispose();
    _nameController.dispose();
    _versionController.dispose();
    _authorController.dispose();
    _descriptionController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  int _allocateEntityId() {
    int maxId = 0;
    for (final obj in _objects) {
      if (obj.id > maxId) maxId = obj.id;
    }
    for (final entity in _controller.store.entities) {
      if (entity != null && entity.id > maxId) maxId = entity.id;
    }
    return maxId + 1;
  }

  void _pushState() {
    _undoStack.add(_EditorState(
      objects: List.of(_objects),
      payloads: List.of(_payloads),
      tags: List.of(_tags),
      properties: List.of(_properties),
    ).copy());
    if (_undoStack.length > _maxHistoryDepth) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_EditorState(
      objects: List.of(_objects),
      payloads: List.of(_payloads),
      tags: List.of(_tags),
      properties: List.of(_properties),
    ).copy());
    final state = _undoStack.removeLast();
    setState(() {
      _objects
        ..clear()
        ..addAll(state.objects);
      _payloads
        ..clear()
        ..addAll(state.payloads);
      _tags
        ..clear()
        ..addAll(state.tags);
      _properties
        ..clear()
        ..addAll(state.properties);
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_EditorState(
      objects: List.of(_objects),
      payloads: List.of(_payloads),
      tags: List.of(_tags),
      properties: List.of(_properties),
    ).copy());
    final state = _redoStack.removeLast();
    setState(() {
      _objects
        ..clear()
        ..addAll(state.objects);
      _payloads
        ..clear()
        ..addAll(state.payloads);
      _tags
        ..clear()
        ..addAll(state.tags);
      _properties
        ..clear()
        ..addAll(state.properties);
    });
  }

  void _addObject() {
    _pushState();
    final nextId = _allocateEntityId();
    setState(() {
      _objects.add(
        Entity(
          id: nextId,
          packageId: '',
          name: 'Entity $nextId',
          category: 'Dynamic Sprite',
          activePayloadId: 0,
        ),
      );
      _tags.add(EntityTag(entityId: nextId, name: 'Interactive'));
      _properties.addAll([
        EntityProperty(entityId: nextId, key: 'kind', value: 'rectangle'),
        EntityProperty(
            entityId: nextId, key: 'x', value: '${100.0 + (nextId * 40.0)}'),
        EntityProperty(
            entityId: nextId, key: 'y', value: '${100.0 + (nextId * 40.0)}'),
        EntityProperty(entityId: nextId, key: 'width', value: '80.0'),
        EntityProperty(entityId: nextId, key: 'height', value: '80.0'),
        EntityProperty(
            entityId: nextId, key: 'speedX', value: '${3.0 + nextId}'),
        EntityProperty(
            entityId: nextId, key: 'speedY', value: '${2.0 + nextId}'),
        EntityProperty(entityId: nextId, key: 'color', value: '0xFF00FFCC'),
        EntityProperty(entityId: nextId, key: 'text', value: 'BLOCK'),
      ]);
    });
  }

  void _removeObject(int index) {
    _pushState();
    final obj = _objects[index];
    setState(() {
      _objects.removeAt(index);
      _tags.removeWhere((t) => t.entityId == obj.id);
      _payloads.removeWhere((p) => p.entityId == obj.id);
      _properties.removeWhere((p) => p.entityId == obj.id);
    });
  }

  void _editObject(int index) {
    final obj = _objects[index];
    final entTags = _tags.where((t) => t.entityId == obj.id);
    final entPayloads = _payloads.where((p) => p.entityId == obj.id);
    final entProps = _properties.where((p) => p.entityId == obj.id);
    final propsMap = {for (var p in entProps) p.key: p.value};

    final nameCtrl = TextEditingController(text: obj.name);
    final categoryCtrl = TextEditingController(text: obj.category);
    final tagCtrl = TextEditingController(
      text: entTags.map((t) => t.name).join(', '),
    );
    final payloadPathCtrl = TextEditingController(
      text: entPayloads.isEmpty ? '' : entPayloads.first.assetPath,
    );

    final payloadTypeNotifier =
        ValueNotifier<String>(propsMap['payloadType'] ?? 'physics_body');
    final kindNotifier = ValueNotifier<String>(propsMap['kind'] ?? 'rectangle');
    final propsControllers = <String, TextEditingController>{};
    propsMap.forEach((key, value) {
      if (key != 'kind' && key != 'payloadType') {
        propsControllers[key] = TextEditingController(text: value);
      }
    });

    // Ensure common properties exist if missing
    for (final prop in [
      'x',
      'y',
      'width',
      'height',
      'speedX',
      'speedY',
      'color',
      'text'
    ]) {
      if (!propsControllers.containsKey(prop)) {
        if (prop == 'color') {
          propsControllers[prop] = TextEditingController(text: '0xFF00FFCC');
        } else if (prop == 'text') {
          propsControllers[prop] = TextEditingController(text: 'BLOCK');
        } else {
          propsControllers[prop] = TextEditingController(text: '80.0');
        }
      }
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xff0d0d0d),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Color(0xff1b1b1b)),
          ),
          title: const Text(
            'Edit Entity Config',
            style: TextStyle(
              fontFamily: 'Georgia',
              color: Color(0xffe0dcd3),
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _dialogTextField('Name', nameCtrl),
                  const SizedBox(height: 8),
                  _dialogTextField('Category', categoryCtrl),
                  const SizedBox(height: 8),
                  _dialogTextField('Tags (comma separated)', tagCtrl),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _dialogTextField(
                          'Payload Asset Path',
                          payloadPathCtrl,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.folder_open,
                            color: Colors.white38, size: 20),
                        tooltip: 'Pick payload asset',
                        onPressed: () async {
                          final result = await FilePicker.platform.pickFiles(
                            type: FileType.any,
                            allowMultiple: false,
                            withData: false,
                          );
                          if (result != null &&
                              result.files.isNotEmpty &&
                              result.files.single.path != null) {
                            payloadPathCtrl.text = result.files.single.path!;
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _PayloadPreview(path: payloadPathCtrl.text),
                  const SizedBox(height: 12),
                  const Text(
                    'Payload Type',
                    style: TextStyle(
                      fontFamily: 'Courier',
                      fontSize: 11,
                      color: Colors.white38,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ValueListenableBuilder<String>(
                    valueListenable: payloadTypeNotifier,
                    builder: (context, payloadType, child) {
                      return DropdownButton<String>(
                        value: payloadType,
                        dropdownColor: const Color(0xff161616),
                        style:
                            const TextStyle(color: Colors.white, fontSize: 12),
                        isExpanded: true,
                        underline: Container(
                            height: 1, color: const Color(0xff1b1b1b)),
                        items: const [
                          DropdownMenuItem(
                              value: 'physics_body',
                              child: Text('Physics Body')),
                          DropdownMenuItem(
                              value: 'rectangle', child: Text('Rectangle')),
                          DropdownMenuItem(
                              value: 'sprite', child: Text('Sprite')),
                          DropdownMenuItem(
                              value: 'sound', child: Text('Sound')),
                          DropdownMenuItem(value: 'text', child: Text('Text')),
                          DropdownMenuItem(
                              value: 'transform', child: Text('Transform')),
                        ],
                        onChanged: (val) => payloadTypeNotifier.value = val!,
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Render Geometry Type',
                    style: TextStyle(
                      fontFamily: 'Courier',
                      fontSize: 11,
                      color: Colors.white38,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ValueListenableBuilder<String>(
                    valueListenable: kindNotifier,
                    builder: (context, kind, child) {
                      return Row(
                        children: [
                          Radio<String>(
                            value: 'rectangle',
                            groupValue: kind,
                            activeColor: const Color(0xff00ffcc),
                            onChanged: (val) => kindNotifier.value = val!,
                          ),
                          const Text('Rectangle',
                              style:
                                  TextStyle(color: Colors.white, fontSize: 12)),
                          const SizedBox(width: 12),
                          Radio<String>(
                            value: 'text',
                            groupValue: kind,
                            activeColor: const Color(0xff00ffcc),
                            onChanged: (val) => kindNotifier.value = val!,
                          ),
                          const Text('Text Label',
                              style:
                                  TextStyle(color: Colors.white, fontSize: 12)),
                        ],
                      );
                    },
                  ),
                  const Divider(color: Color(0xff1b1b1b), height: 20),
                  const Text(
                    'Properties Mapping',
                    style: TextStyle(
                      fontFamily: 'Courier',
                      fontSize: 11,
                      color: Colors.white38,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _dialogTextField('Position X', propsControllers['x']!),
                  const SizedBox(height: 8),
                  _dialogTextField('Position Y', propsControllers['y']!),
                  const SizedBox(height: 8),
                  _dialogTextField(
                      'Width / Font Size', propsControllers['width']!),
                  const SizedBox(height: 8),
                  _dialogTextField('Height', propsControllers['height']!),
                  const SizedBox(height: 8),
                  _dialogTextField('Speed X', propsControllers['speedX']!),
                  const SizedBox(height: 8),
                  _dialogTextField('Speed Y', propsControllers['speedY']!),
                  const SizedBox(height: 8),
                  _dialogTextField(
                      'Color Hex (0x...)', propsControllers['color']!),
                  const SizedBox(height: 8),
                  _dialogTextField(
                      'Label Text (Only for Text)', propsControllers['text']!),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCEL',
                  style: TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      fontFamily: 'Courier')),
            ),
            TextButton(
              onPressed: () {
                _pushState();
                setState(() {
                  _tags.removeWhere((t) => t.entityId == obj.id);
                  _payloads.removeWhere((p) => p.entityId == obj.id);
                  _properties.removeWhere((p) => p.entityId == obj.id);

                  final newTags = tagCtrl.text
                      .split(',')
                      .map((t) => t.trim())
                      .where((t) => t.isNotEmpty)
                      .map((t) => EntityTag(entityId: obj.id, name: t))
                      .toList();
                  _tags.addAll(newTags);

                  int activePayloadId = 0;
                  if (payloadPathCtrl.text.isNotEmpty) {
                    activePayloadId = 1;
                    _payloads.add(
                      EntityPayload(
                        id: 1,
                        entityId: obj.id,
                        name: 'Payload ${obj.name}',
                        assetPath: payloadPathCtrl.text.trim(),
                        version: '1.0',
                      ),
                    );
                  }

                  final Map<String, String> newProps = {
                    'kind': kindNotifier.value,
                    'payloadType': payloadTypeNotifier.value,
                  };
                  propsControllers.forEach((key, ctrl) {
                    newProps[key] = ctrl.text.trim();
                  });
                  newProps.forEach((k, v) {
                    _properties.add(
                        EntityProperty(entityId: obj.id, key: k, value: v));
                  });

                  _objects[index] = Entity(
                    id: obj.id,
                    packageId: '',
                    name: nameCtrl.text.trim(),
                    category: categoryCtrl.text.trim(),
                    activePayloadId: activePayloadId,
                  );
                });
                Navigator.pop(context);
              },
              child: const Text(
                'APPLY',
                style: TextStyle(
                    color: Color(0xff00ffcc),
                    fontSize: 11,
                    fontFamily: 'Courier',
                    fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _dialogTextField(String label, TextEditingController ctrl) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xff161616),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xff1b1b1b)),
      ),
      child: TextField(
        controller: ctrl,
        style: const TextStyle(
            color: Colors.white, fontSize: 12, fontFamily: 'Arial'),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white38, fontSize: 10),
          border: InputBorder.none,
          floatingLabelBehavior: FloatingLabelBehavior.never,
          hintText: label,
          hintStyle: const TextStyle(color: Colors.white24, fontSize: 11),
        ),
      ),
    );
  }

  Future<void> _compilePackage({required bool runLive}) async {
    if (!_formKey.currentState!.validate()) return;
    if (_objects.isEmpty) {
      _showErrorSnackBar('Add at least one object entity!');
      return;
    }

    setState(() {
      _isCompiling = true;
    });

    try {
      final width = int.tryParse(_widthController.text.trim()) ?? 1000;
      final height = int.tryParse(_heightController.text.trim()) ?? 1000;
      final packId = _packIdController.text.trim();

      await _controller.createAndCompilePackage(
        packId: packId,
        name: _nameController.text.trim(),
        version: _versionController.text.trim(),
        author: _authorController.text.trim(),
        description: _descriptionController.text.trim(),
        canvasWidth: width,
        canvasHeight: height,
        entities: _objects,
        payloads: _payloads,
        tags: _tags,
        properties: _properties,
      );

      if (runLive) {
        final bindings = MalphasBindings();
        if (bindings.isNativeAvailable) {
          bindings.pauseEngine(true);
          try {
            final workspace = _controller.resolveWorkspaceRoot();
            final mspFile = File('$workspace/packages/$packId.msp');
            final systemFile = _resolveSystemFile(workspace, packId);
            if (mspFile.existsSync()) {
              try {
                bindings.loadMsp(mspFile.path);
                if (systemFile != null) {
                  bindings.loadSystem(systemFile);
                }
              } on FFIException catch (e) {
                debugPrint('Live run failed: ${e.message}');
              }
              final pack = _controller
                  .getAllPackages()
                  .firstWhere((p) => p.id == packId);
              await _controller.setPackageLoaded(packId, loaded: true);
              await _controller.preloadPayloads(pack);
            }
          } finally {
            bindings.pauseEngine(false);
          }
        }

        if (widget.activeEnvironment != null) {
          final env = widget.activeEnvironment!;
          env.packageIds.remove(packId);
          env.packageIds.insert(0, packId);
        }
      }

      _showSuccessSnackBar(runLive
          ? 'Package compiled and launched live!'
          : 'Package compiled and registered successfully!');

      if (mounted) {
        Navigator.pop(context, runLive ? 'run_live' : null);
      }
    } catch (e) {
      _showErrorSnackBar('Compilation error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isCompiling = false;
        });
      }
    }
  }

  String? _resolveSystemFile(String workspace, String packId) {
    final exts = Platform.isWindows
        ? ['.mxc', '.dll']
        : Platform.isMacOS
            ? ['.mxc', '.dylib']
            : ['.mxc', '.so'];
    for (final ext in exts) {
      final candidates = [
        '$workspace/packages/$packId$ext',
        '$workspace/$packId$ext',
        '$workspace/flutter_app/motors/$packId$ext',
      ];
      for (final candidate in candidates) {
        if (File(candidate).existsSync()) return candidate;
      }
    }
    return null;
  }

  void _showErrorSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xff0d0d0d),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xffd32f2f)),
        ),
        content: Text(
          msg,
          style: const TextStyle(
              fontFamily: 'Courier', color: Color(0xffe0dcd3), fontSize: 11),
        ),
      ),
    );
  }

  void _showSuccessSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xff0d0d0d),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xff00ffcc)),
        ),
        content: Text(
          msg,
          style: const TextStyle(
              fontFamily: 'Courier', color: Color(0xff00ffcc), fontSize: 11),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff000000),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios,
                          color: Color(0xffe0dcd3), size: 16),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Text(
                      'PACKAGE CREATOR',
                      style: TextStyle(
                        fontFamily: 'Georgia',
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xffe0dcd3),
                      ),
                    ),
                    const SizedBox(width: 48), // Spacer
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    children: [
                      _buildTextField('Package ID (Alphanumeric/Underscore)',
                          _packIdController, (val) {
                        if (val == null || val.trim().isEmpty) {
                          return 'Required';
                        }
                        if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$')
                            .hasMatch(val.trim())) {
                          return 'Letters, numbers, underscores only (start with letter)';
                        }
                        return null;
                      }),
                      const SizedBox(height: 12),
                      _buildTextField(
                          'Friendly Name',
                          _nameController,
                          (val) => val == null || val.trim().isEmpty
                              ? 'Required'
                              : null),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                              child: _buildTextField(
                                  'Version',
                                  _versionController,
                                  (val) => val == null || val.trim().isEmpty
                                      ? 'Required'
                                      : null)),
                          const SizedBox(width: 12),
                          Expanded(
                              child: _buildTextField(
                                  'Author',
                                  _authorController,
                                  (val) => val == null || val.trim().isEmpty
                                      ? 'Required'
                                      : null)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildTextField(
                          'Description', _descriptionController, null,
                          maxLines: 2),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                              child: _buildTextField(
                                  'Canvas Width',
                                  _widthController,
                                  (val) => int.tryParse(val ?? '') == null
                                      ? 'Must be integer'
                                      : null)),
                          const SizedBox(width: 12),
                          Expanded(
                              child: _buildTextField(
                                  'Canvas Height',
                                  _heightController,
                                  (val) => int.tryParse(val ?? '') == null
                                      ? 'Must be integer'
                                      : null)),
                        ],
                      ),
                      const Divider(color: Color(0xff1b1b1b), height: 32),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Object List',
                            style: TextStyle(
                              fontFamily: 'Georgia',
                              fontSize: 15,
                              color: Color(0xffe0dcd3),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.undo,
                                    size: 18, color: Colors.white54),
                                tooltip: 'Undo',
                                onPressed: _undoStack.isEmpty ? null : _undo,
                              ),
                              IconButton(
                                icon: const Icon(Icons.redo,
                                    size: 18, color: Colors.white54),
                                tooltip: 'Redo',
                                onPressed: _redoStack.isEmpty ? null : _redo,
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xff0d0d0d),
                                  side: const BorderSide(
                                      color: Color(0xff1b1b1b)),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20)),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 8),
                                ),
                                icon: const Icon(Icons.add,
                                    size: 14, color: Color(0xff00ffcc)),
                                label: const Text(
                                  'ADD ENTITY',
                                  style: TextStyle(
                                      fontFamily: 'Courier',
                                      fontSize: 10,
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold),
                                ),
                                onPressed: _addObject,
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_objects.isEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 30),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xff0d0d0d),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: const Color(0xff161616)),
                          ),
                          child: const Text(
                            'No entities configured. Click ADD ENTITY above.',
                            style: TextStyle(
                                color: Colors.white24,
                                fontSize: 11,
                                fontFamily: 'Arial'),
                          ),
                        )
                      else
                        ...List.generate(_objects.length, (index) {
                          final obj = _objects[index];
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xff0d0d0d),
                              borderRadius: BorderRadius.circular(24),
                              border:
                                  Border.all(color: const Color(0xff1b1b1b)),
                            ),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 4),
                              title: Text(
                                obj.name,
                                style: const TextStyle(
                                    fontFamily: 'Arial',
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold),
                              ),
                              subtitle: Builder(
                                builder: (context) {
                                  final kind = _properties
                                      .firstWhere(
                                          (p) =>
                                              p.entityId == obj.id &&
                                              p.key == 'kind',
                                          orElse: () => const EntityProperty(
                                              entityId: 0,
                                              key: 'kind',
                                              value: 'rectangle'))
                                      .value;
                                  final tagList = _tags
                                      .where((t) => t.entityId == obj.id)
                                      .map((t) => t.name)
                                      .join(', ');
                                  return Text(
                                    '${obj.category} • ${kind.toUpperCase()} • Tags: $tagList',
                                    style: const TextStyle(
                                        fontFamily: 'Courier',
                                        color: Colors.white38,
                                        fontSize: 9),
                                  );
                                },
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit,
                                        color: Color(0xff00ffcc), size: 16),
                                    onPressed: () => _editObject(index),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete,
                                        color: Colors.redAccent, size: 16),
                                    onPressed: () => _removeObject(index),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
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
                            backgroundColor: const Color(0xff0d0d0d),
                            side: const BorderSide(color: Color(0xff1b1b1b)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24)),
                          ),
                          onPressed: _isCompiling
                              ? null
                              : () => _compilePackage(runLive: false),
                          child: _isCompiling
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                      color: Colors.white38, strokeWidth: 2),
                                )
                              : const Text(
                                  'SAVE & COMPILE',
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
                            backgroundColor: _isCompiling
                                ? const Color(0xff161616)
                                : const Color(0xff00ffcc),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24)),
                          ),
                          onPressed: _isCompiling
                              ? null
                              : () => _compilePackage(runLive: true),
                          child: _isCompiling
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                      color: Colors.black38, strokeWidth: 2),
                                )
                              : const Text(
                                  'COMPILE & RUN LIVE',
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(
    String label,
    TextEditingController ctrl,
    String? Function(String?)? validator, {
    int maxLines = 1,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xff0d0d0d),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xff1b1b1b)),
      ),
      child: TextFormField(
        controller: ctrl,
        maxLines: maxLines,
        validator: validator,
        style: const TextStyle(
            color: Colors.white, fontSize: 13, fontFamily: 'Arial'),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white38, fontSize: 11),
          border: InputBorder.none,
          errorStyle: const TextStyle(
              fontFamily: 'Courier', fontSize: 10, color: Colors.redAccent),
        ),
      ),
    );
  }
}

/// Immutable snapshot of the package creator's mutable state.
class _EditorState {
  final List<Entity> objects;
  final List<EntityPayload> payloads;
  final List<EntityTag> tags;
  final List<EntityProperty> properties;

  const _EditorState({
    required this.objects,
    required this.payloads,
    required this.tags,
    required this.properties,
  });

  _EditorState copy() => _EditorState(
        objects: List.of(objects),
        payloads: List.of(payloads),
        tags: List.of(tags),
        properties: List.of(properties),
      );
}

/// Tiny asset preview for the payload editor dialog.
class _PayloadPreview extends StatelessWidget {
  final String path;

  const _PayloadPreview({required this.path});

  bool get _isImage {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp');
  }

  @override
  Widget build(BuildContext context) {
    if (path.isEmpty) {
      return const Text(
        'No asset selected.',
        style: TextStyle(
          fontFamily: 'Courier',
          fontSize: 10,
          color: Colors.white24,
        ),
      );
    }
    if (_isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.file(
          File(path),
          height: 80,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => const Text(
            'Unable to preview image.',
            style: TextStyle(
              fontFamily: 'Courier',
              fontSize: 10,
              color: Colors.white24,
            ),
          ),
        ),
      );
    }
    return Text(
      'Asset: ${path.split(Platform.pathSeparator).last}',
      style: const TextStyle(
        fontFamily: 'Courier',
        fontSize: 10,
        color: Colors.white38,
      ),
    );
  }
}

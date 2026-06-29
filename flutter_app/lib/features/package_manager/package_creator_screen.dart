import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/ffi/malphas_bindings.dart';
import '../../core/services/entity_bootstrap_service.dart';
import '../hub/environment_model.dart';
import 'models.dart';
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

  final List<MalphasObject> _objects = [];
  bool _isCompiling = false;

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

  void _addObject() {
    final nextId = _objects.length + 1;
    setState(() {
      _objects.add(
        MalphasObject(
          id: '$nextId',
          name: 'Entity $nextId',
          category: 'Dynamic Sprite',
          properties: {
            'kind': 'rectangle',
            'x': '${100.0 + (nextId * 40.0)}',
            'y': '${100.0 + (nextId * 40.0)}',
            'width': '80.0',
            'height': '80.0',
            'speedX': '${3.0 + nextId}',
            'speedY': '${2.0 + nextId}',
            'color': '0xFF00FFCC',
          },
          tags: [const MalphasTag(name: 'Interactive', isPublic: true)],
          skins: [],
        ),
      );
    });
  }

  void _removeObject(int index) {
    setState(() {
      _objects.removeAt(index);
    });
  }

  void _editObject(int index) {
    final obj = _objects[index];
    final nameCtrl = TextEditingController(text: obj.name);
    final categoryCtrl = TextEditingController(text: obj.category);
    final tagCtrl = TextEditingController(
      text: obj.tags.map((t) => t.name).join(', '),
    );
    final skinPathCtrl = TextEditingController(
      text: obj.skins.isEmpty ? '' : obj.skins.first.assetPath,
    );

    final kindNotifier =
        ValueNotifier<String>(obj.properties['kind'] ?? 'rectangle');
    final propsControllers = <String, TextEditingController>{};
    obj.properties.forEach((key, value) {
      if (key != 'kind') {
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
                  _dialogTextField(
                      'Skin Image Path (e.g. assets/red.png)', skinPathCtrl),
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
                setState(() {
                  final newTags = tagCtrl.text
                      .split(',')
                      .map((t) => t.trim())
                      .where((t) => t.isNotEmpty)
                      .map((t) => MalphasTag(name: t, isPublic: true))
                      .toList();

                  final newSkins = <MalphasSkin>[];
                  if (skinPathCtrl.text.isNotEmpty) {
                    newSkins.add(
                      MalphasSkin(
                        id: 'skin_${obj.id}',
                        name: 'Skin ${obj.name}',
                        assetPath: skinPathCtrl.text.trim(),
                        version: '1.0',
                      ),
                    );
                  }

                  final Map<String, String> newProps = {
                    'kind': kindNotifier.value,
                  };
                  propsControllers.forEach((key, ctrl) {
                    newProps[key] = ctrl.text.trim();
                  });

                  _objects[index] = MalphasObject(
                    id: obj.id,
                    name: nameCtrl.text.trim(),
                    category: categoryCtrl.text.trim(),
                    properties: newProps,
                    tags: newTags,
                    skins: newSkins,
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
        objects: _objects,
      );

      final bindings = MalphasBindings();
      if (runLive && bindings.isNativeAvailable) {
        bindings.pauseEngine(true);
        try {
          final workspace = _controller.resolveWorkspaceRoot();
          final mhpFile = File('$workspace/packages/$packId.mhp');
          if (mhpFile.existsSync()) {
            final loadResult = bindings.loadPack(mhpFile.path);
            if (loadResult == 0) {
              final pack = _controller
                  .getAllPackages()
                  .firstWhere((p) => p.id == packId);
              final bootstrap = EntityBootstrapService(bindings);
              bootstrap.configurePackageScene(pack);

              _controller.setPackageLoaded(packId, loaded: true);
              await _controller.preloadSkins(pack);
            }
          }
        } finally {
          bindings.pauseEngine(false);
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
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xff0d0d0d),
                              side: const BorderSide(color: Color(0xff1b1b1b)),
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
                              subtitle: Text(
                                '${obj.category} • ${obj.properties['kind']?.toUpperCase()} • Tags: ${obj.tags.map((t) => t.name).join(",")}',
                                style: const TextStyle(
                                    fontFamily: 'Courier',
                                    color: Colors.white38,
                                    fontSize: 9),
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

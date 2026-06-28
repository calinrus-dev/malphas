import 'package:flutter/material.dart';
import '../workspace/workspace_screen.dart';
import '../package_manager/package_manager_screen.dart';
import '../engine_manager/engine_manager_screen.dart';
import '../package_manager/package_controller.dart';
import '../engine_manager/engine_controller.dart';

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
}

class MalphasHubScreen extends StatefulWidget {
  const MalphasHubScreen({super.key});

  @override
  State<MalphasHubScreen> createState() => _MalphasHubScreenState();
}

class _MalphasHubScreenState extends State<MalphasHubScreen> {
  bool _isGridView = true;
  late List<MalphasEnvironment> _environments;

  @override
  void initState() {
    super.initState();
    EngineController().scanAvailableEngines();
    _buildEnvironments();
  }

  void _buildEnvironments() {
    final packages = PackageController().getAllPackages();
    final engines = EngineController().getAllEngines();
    final firstEngineId = engines.firstOrNull?.id;

    if (packages.isEmpty) {
      _environments = [
        MalphasEnvironment(
          id: 'env_sandbox',
          name: 'Malphas Sandbox',
          accentColor: const Color(0xffe0dcd3),
          engineId: firstEngineId,
          packageIds: [],
        ),
      ];
    } else {
      _environments = packages.map((pack) {
        return MalphasEnvironment(
          id: pack.id,
          name: pack.name,
          accentColor: const Color(0xffe0dcd3),
          engineId: firstEngineId,
          packageIds: [pack.id],
        );
      }).toList();
    }
  }

  void _showCreateEnvironmentDialog() {
    showDialog(
      context: context,
      builder: (context) {
        String name = '';
        String? selectedEngineId =
            EngineController().getAllEngines().firstOrNull?.id;
        List<String> selectedPackageIds = [];

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xff0d0d0d),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: const BorderSide(color: Color(0xff1b1b1b)),
              ),
              title: const Text('NUEVO ENTORNO',
                  style: TextStyle(
                      fontFamily: 'Georgia',
                      color: Color(0xffe0dcd3),
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              content: SizedBox(
                width: 320,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('NOMBRE DEL CANAL',
                          style: TextStyle(
                              fontFamily: 'Arial',
                              fontSize: 9,
                              color: Colors.white38,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xff1b1b1b))),
                        child: TextField(
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13),
                          decoration: const InputDecoration(
                              hintText: 'Ej. Mecatron Core v2',
                              hintStyle: TextStyle(
                                  color: Colors.white24, fontSize: 12),
                              border: InputBorder.none),
                          onChanged: (val) => name = val,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text('ACOPLAR MOTOR',
                          style: TextStyle(
                              fontFamily: 'Arial',
                              fontSize: 9,
                              color: Colors.white38,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xff1b1b1b))),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            dropdownColor: const Color(0xff0d0d0d),
                            value: selectedEngineId,
                            isExpanded: true,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                            items: EngineController().getAllEngines().map((e) {
                              return DropdownMenuItem(
                                  value: e.id, child: Text(e.name));
                            }).toList(),
                            onChanged: (val) {
                              setDialogState(() {
                                selectedEngineId = val;
                              });
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text('CARGAR PAQUETES ACTIVOS',
                          style: TextStyle(
                              fontFamily: 'Arial',
                              fontSize: 9,
                              color: Colors.white38,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Column(
                        children:
                            PackageController().getAllPackages().map((pack) {
                          final isSelected =
                              selectedPackageIds.contains(pack.id);
                          return CheckboxListTile(
                            title: Text(pack.name,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12)),
                            subtitle: Text(pack.version,
                                style: const TextStyle(
                                    color: Colors.white24, fontSize: 10)),
                            value: isSelected,
                            activeColor: const Color(0xffe0dcd3),
                            checkColor: Colors.black,
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                            onChanged: (val) {
                              setDialogState(() {
                                if (val == true) {
                                  selectedPackageIds.add(pack.id);
                                } else {
                                  selectedPackageIds.remove(pack.id);
                                }
                              });
                            },
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  child: const Text('CANCELAR',
                      style: TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                TextButton(
                  child: const Text('CREAR',
                      style: TextStyle(
                          color: Color(0xffe0dcd3),
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                  onPressed: () {
                    if (name.trim().isNotEmpty) {
                      setState(() {
                        _environments.add(
                          MalphasEnvironment(
                            id: 'env_${DateTime.now().millisecondsSinceEpoch}',
                            name: name.trim(),
                            accentColor: const Color(0xffe0dcd3),
                            engineId: selectedEngineId,
                            packageIds: selectedPackageIds,
                          ),
                        );
                      });
                      Navigator.of(context).pop();
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showEditEnvironmentDialog(MalphasEnvironment env) {
    showDialog(
      context: context,
      builder: (context) {
        String name = env.name;
        String? selectedEngineId =
            env.engineId ?? EngineController().getAllEngines().firstOrNull?.id;
        List<String> selectedPackageIds = List.from(env.packageIds);

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xff0d0d0d),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: const BorderSide(color: Color(0xff1b1b1b)),
              ),
              title: const Text('EDITAR ENTORNO',
                  style: TextStyle(
                      fontFamily: 'Georgia',
                      color: Color(0xffe0dcd3),
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              content: SizedBox(
                width: 320,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('NOMBRE DEL CANAL',
                          style: TextStyle(
                              fontFamily: 'Arial',
                              fontSize: 9,
                              color: Colors.white38,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xff1b1b1b))),
                        child: TextFormField(
                          initialValue: name,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13),
                          decoration:
                              const InputDecoration(border: InputBorder.none),
                          onChanged: (val) => name = val,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text('ACOPLAR MOTOR',
                          style: TextStyle(
                              fontFamily: 'Arial',
                              fontSize: 9,
                              color: Colors.white38,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                            color: Colors.black,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xff1b1b1b))),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            dropdownColor: const Color(0xff0d0d0d),
                            value: selectedEngineId,
                            isExpanded: true,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                            items: EngineController().getAllEngines().map((e) {
                              return DropdownMenuItem(
                                  value: e.id, child: Text(e.name));
                            }).toList(),
                            onChanged: (val) {
                              setDialogState(() {
                                selectedEngineId = val;
                              });
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text('CARGAR PAQUETES ACTIVOS',
                          style: TextStyle(
                              fontFamily: 'Arial',
                              fontSize: 9,
                              color: Colors.white38,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Column(
                        children:
                            PackageController().getAllPackages().map((pack) {
                          final isSelected =
                              selectedPackageIds.contains(pack.id);
                          return CheckboxListTile(
                            title: Text(pack.name,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12)),
                            subtitle: Text(pack.version,
                                style: const TextStyle(
                                    color: Colors.white24, fontSize: 10)),
                            value: isSelected,
                            activeColor: const Color(0xffe0dcd3),
                            checkColor: Colors.black,
                            controlAffinity: ListTileControlAffinity.leading,
                            contentPadding: EdgeInsets.zero,
                            onChanged: (val) {
                              setDialogState(() {
                                if (val == true) {
                                  selectedPackageIds.add(pack.id);
                                } else {
                                  selectedPackageIds.remove(pack.id);
                                }
                              });
                            },
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  child: const Text('CANCELAR',
                      style: TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                TextButton(
                  child: const Text('GUARDAR',
                      style: TextStyle(
                          color: Color(0xffe0dcd3),
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                  onPressed: () {
                    if (name.trim().isNotEmpty) {
                      setState(() {
                        env.name = name.trim();
                        env.engineId = selectedEngineId;
                        env.packageIds = selectedPackageIds;
                      });
                      Navigator.of(context).pop();
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showRenameDialog(MalphasEnvironment env) {
    showDialog(
      context: context,
      builder: (context) {
        String name = env.name;
        return AlertDialog(
          backgroundColor: const Color(0xff0d0d0d),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Color(0xff1b1b1b)),
          ),
          title: const Text('RENOMBRAR',
              style: TextStyle(
                  fontFamily: 'Georgia',
                  color: Color(0xffe0dcd3),
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          content: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xff1b1b1b))),
            child: TextFormField(
              initialValue: name,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: const InputDecoration(border: InputBorder.none),
              onChanged: (val) => name = val,
            ),
          ),
          actions: [
            TextButton(
              child: const Text('CANCELAR',
                  style: TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text('ACEPTAR',
                  style: TextStyle(
                      color: Color(0xffe0dcd3),
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
              onPressed: () {
                if (name.trim().isNotEmpty) {
                  setState(() {
                    env.name = name.trim();
                  });
                  Navigator.of(context).pop();
                }
              },
            ),
          ],
        );
      },
    );
  }

  void _confirmDelete(MalphasEnvironment env) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xff0d0d0d),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: Color(0xff1b1b1b)),
          ),
          title: const Text('ELIMINAR ENTORNO',
              style: TextStyle(
                  fontFamily: 'Georgia',
                  color: Colors.redAccent,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          content: Text('¿Seguro que deseas eliminar el entorno "${env.name}"?',
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          actions: [
            TextButton(
              child: const Text('CANCELAR',
                  style: TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: const Text('ELIMINAR',
                  style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
              onPressed: () {
                setState(() {
                  _environments.removeWhere((e) => e.id == env.id);
                });
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void _showEnvironmentOptions(MalphasEnvironment env) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xff0d0d0d),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading:
                    const Icon(Icons.edit_outlined, color: Color(0xffe0dcd3)),
                title: const Text('Editar Entorno',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.of(context).pop();
                  _showEditEnvironmentDialog(env);
                },
              ),
              ListTile(
                leading: const Icon(Icons.text_fields_outlined,
                    color: Color(0xffe0dcd3)),
                title: const Text('Renombrar',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.of(context).pop();
                  _showRenameDialog(env);
                },
              ),
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('Eliminar',
                    style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.of(context).pop();
                  _confirmDelete(env);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _navigateToWorkspace(MalphasEnvironment env) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => WorkspaceScreen(environment: env),
    ));
  }

  @override
  Widget build(BuildContext context) {
    // Clasificación estricta: Pinned arriba del todo
    final sortedEnvs = [..._environments];
    sortedEnvs
        .sort((a, b) => (b.isPinned ? 1 : 0).compareTo(a.isPinned ? 1 : 0));

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Malphas Chasis',
            style: TextStyle(
                fontFamily: 'Georgia', fontSize: 22, color: Color(0xffe0dcd3))),
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [
          PopupMenuButton<bool>(
            icon: const Icon(Icons.remove_red_eye_outlined,
                color: Color(0xffe0dcd3)),
            onSelected: (isGrid) => setState(() => _isGridView = isGrid),
            color: const Color(0xff0d0d0d),
            itemBuilder: (context) => [
              const PopupMenuItem(
                  value: true,
                  child: Text('Mosaico (Grid)',
                      style: TextStyle(color: Colors.white))),
              const PopupMenuItem(
                  value: false,
                  child: Text('Lista (List)',
                      style: TextStyle(color: Colors.white))),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.add_box_outlined, color: Color(0xffe0dcd3)),
            onPressed: _showCreateEnvironmentDialog,
          )
        ],
      ),
      drawer: _buildGlobalDrawer(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('OPERATIONAL ENVIRONMENTS',
                  style: TextStyle(
                      fontFamily: 'Arial',
                      fontSize: 10,
                      color: Colors.white24,
                      letterSpacing: 1,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Expanded(
                child: _isGridView
                    ? _buildGridView(sortedEnvs)
                    : _buildListView(sortedEnvs),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGridView(List<MalphasEnvironment> sortedEnvs) {
    return GridView.builder(
      physics: const BouncingScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 1.2,
      ),
      itemCount: sortedEnvs.length,
      itemBuilder: (context, index) {
        final env = sortedEnvs[index];
        final originalIndex = _environments.indexOf(env);

        return DragTarget<int>(
          onAccept: (fromIndex) {
            setState(() {
              final item = _environments.removeAt(fromIndex);
              _environments.insert(originalIndex, item);
            });
          },
          builder: (context, candidateData, rejectedData) {
            return GestureDetector(
              onTap: () => _navigateToWorkspace(env),
              onLongPress: () => _showEnvironmentOptions(env),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xff0d0d0d),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xff1b1b1b)),
                ),
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                color: env.accentColor,
                                shape: BoxShape.circle)),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Icon(
                              env.isPinned
                                  ? Icons.push_pin
                                  : Icons.push_pin_outlined,
                              size: 14,
                              color: env.isPinned
                                  ? env.accentColor
                                  : Colors.white24),
                          onPressed: () =>
                              setState(() => env.isPinned = !env.isPinned),
                        )
                      ],
                    ),
                    LongPressDraggable<int>(
                      data: originalIndex,
                      feedback: Material(
                        color: Colors.transparent,
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                              color: const Color(0xff161616),
                              borderRadius: BorderRadius.circular(16),
                              border:
                                  Border.all(color: const Color(0xff222222))),
                          child: Text(env.name,
                              style: const TextStyle(
                                  fontFamily: 'Georgia',
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xffe0dcd3))),
                        ),
                      ),
                      child: Text(env.name,
                          style: const TextStyle(
                              fontFamily: 'Georgia',
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Color(0xffe0dcd3)),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildListView(List<MalphasEnvironment> sortedEnvs) {
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      itemCount: sortedEnvs.length,
      itemBuilder: (context, index) {
        final env = sortedEnvs[index];
        final originalIndex = _environments.indexOf(env);

        return DragTarget<int>(
          onAccept: (fromIndex) {
            setState(() {
              final item = _environments.removeAt(fromIndex);
              _environments.insert(originalIndex, item);
            });
          },
          builder: (context, candidateData, rejectedData) {
            return GestureDetector(
              onTap: () => _navigateToWorkspace(env),
              onLongPress: () => _showEnvironmentOptions(env),
              child: Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xff0d0d0d),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xff1b1b1b)),
                ),
                child: Row(
                  children: [
                    Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                            color: env.accentColor, shape: BoxShape.circle)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: LongPressDraggable<int>(
                        data: originalIndex,
                        feedback: Material(
                          color: Colors.transparent,
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                                color: const Color(0xff161616),
                                borderRadius: BorderRadius.circular(16),
                                border:
                                    Border.all(color: const Color(0xff222222))),
                            child: Text(env.name,
                                style: const TextStyle(
                                    fontFamily: 'Georgia',
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xffe0dcd3))),
                          ),
                        ),
                        child: Text(env.name,
                            style: const TextStyle(
                                fontFamily: 'Georgia',
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: Color(0xffe0dcd3))),
                      ),
                    ),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: Icon(
                          env.isPinned
                              ? Icons.push_pin
                              : Icons.push_pin_outlined,
                          size: 14,
                          color:
                              env.isPinned ? env.accentColor : Colors.white24),
                      onPressed: () =>
                          setState(() => env.isPinned = !env.isPinned),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildGlobalDrawer() {
    return Drawer(
      backgroundColor: const Color(0xff0d0d0d),
      child: Column(
        children: [
          const DrawerHeader(
            child: Align(
                alignment: Alignment.centerLeft,
                child: Text('MALPHAS SYSTEM',
                    style: TextStyle(
                        fontFamily: 'Georgia',
                        fontSize: 24,
                        color: Color(0xffe0dcd3),
                        fontWeight: FontWeight.bold))),
          ),
          ListTile(
            leading: const Icon(Icons.archive_outlined,
                size: 20, color: Color(0xffe0dcd3)),
            title: const Text('Global Package Hub',
                style: TextStyle(fontFamily: 'Arial', fontSize: 14)),
            onTap: () {
              Navigator.of(context).pop(); // Close drawer
              Navigator.of(context).push(MaterialPageRoute(
                builder: (context) => Scaffold(
                  backgroundColor: Colors.black,
                  appBar: AppBar(
                    backgroundColor: Colors.black,
                    elevation: 0,
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_back_ios,
                          size: 16, color: Color(0xffe0dcd3)),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  body: const PackageManagerPanel(),
                ),
              ));
            },
          ),
          ListTile(
            leading: const Icon(Icons.memory_outlined,
                size: 20, color: Color(0xffe0dcd3)),
            title: const Text('Global Engine Depot',
                style: TextStyle(fontFamily: 'Arial', fontSize: 14)),
            onTap: () {
              Navigator.of(context).pop(); // Close drawer
              Navigator.of(context).push(MaterialPageRoute(
                builder: (context) => Scaffold(
                  backgroundColor: Colors.black,
                  appBar: AppBar(
                    backgroundColor: Colors.black,
                    elevation: 0,
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_back_ios,
                          size: 16, color: Color(0xffe0dcd3)),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  body: const EngineManagerPanel(),
                ),
              ));
            },
          ),
          const Spacer(),
          const Divider(color: Color(0xff1b1b1b)),
          ListTile(
            leading: const Icon(Icons.account_circle_outlined,
                color: Color(0xffe0dcd3)),
            title: const Text('Calin Rus',
                style: TextStyle(
                    fontFamily: 'Arial',
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
            subtitle: Text('Software Architect',
                style: TextStyle(
                    fontFamily: 'Arial',
                    fontSize: 11,
                    color: Colors.white.withOpacity(0.3))),
          ),
          const SizedBox(height: 12)
        ],
      ),
    );
  }
}

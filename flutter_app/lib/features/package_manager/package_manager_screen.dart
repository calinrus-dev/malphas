import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/models/flat_models.dart';
import '../../core/services/payload_decode_service.dart';
import 'package_controller.dart';
import 'package_creator_screen.dart';
import '../hub/environment_model.dart';

enum HubViewMode { packageList, objectGrid }

enum RenderViewMode { card, icon, showcase, payloadGrid }

class PackageManagerPanel extends StatefulWidget {
  final MalphasEnvironment? environment;
  final VoidCallback? onRunLive;

  const PackageManagerPanel({
    super.key,
    this.environment,
    this.onRunLive,
  });

  @override
  State<PackageManagerPanel> createState() => _PackageManagerPanelState();
}

class _PackageManagerPanelState extends State<PackageManagerPanel> {
  final PackageController _controller = PackageController();

  HubViewMode _hubMode = HubViewMode.packageList;
  RenderViewMode _renderMode = RenderViewMode.card;
  EntityPackage? _activePack;

  String _searchQuery = '';
  String _activeTag = 'ALL';

  @override
  void initState() {
    super.initState();
    _controller.init();
  }

  void _showFilterBottomSheet(List<String> tags, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xff0d0d0d),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'FILTER BY TAG',
                style: TextStyle(
                  fontFamily: 'Courier',
                  fontSize: 10,
                  color: Colors.white24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: tags.map((t) {
                  final isSel = t == _activeTag;
                  return ChoiceChip(
                    label: Text(
                      t,
                      style: TextStyle(
                        fontFamily: 'Arial',
                        color: isSel ? Colors.black : Colors.white60,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    selected: isSel,
                    selectedColor: theme.primaryColor,
                    backgroundColor: const Color(0xff161616),
                    onSelected: (sel) {
                      if (sel) {
                        setState(() => _activeTag = t);
                        Navigator.pop(context);
                      }
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: const Color(0xff000000),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              if (_hubMode == HubViewMode.packageList) {
                return _buildPackageList(theme);
              } else {
                return _buildObjectExplorer(theme);
              }
            },
          ),
        ),
      ),
    );
  }

  Widget _buildPackageList(ThemeData theme) {
    final packs = _controller.getAllPackages();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'PACKAGES',
              style: TextStyle(
                fontFamily: 'Georgia',
                fontSize: 24,
                color: Color(0xffe0dcd3),
                fontWeight: FontWeight.bold,
              ),
            ),
            IconButton(
              icon: Icon(
                Icons.add_box_outlined,
                color: theme.primaryColor,
                size: 22,
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => PackageCreatorScreen(
                      activeEnvironment: widget.environment,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        const Divider(color: Color(0xff1b1b1b), height: 24),
        if (packs.isEmpty)
          const Expanded(
            child: Center(
              child: Text(
                'No compiled package compiled. compile demo or create one.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Arial',
                  color: Colors.white24,
                  fontSize: 12,
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              physics: const BouncingScrollPhysics(),
              itemCount: packs.length,
              itemBuilder: (context, idx) {
                final p = packs[idx];
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xff0d0d0d),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xff1b1b1b)),
                  ),
                  child: ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    title: Text(
                      p.name,
                      style: const TextStyle(
                        fontFamily: 'Georgia',
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text(
                          '${p.version} • By ${p.author}',
                          style: const TextStyle(
                            fontFamily: 'Arial',
                            color: Colors.white38,
                            fontSize: 10,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          p.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Arial',
                            color: Colors.white24,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(
                            Icons.folder_open,
                            color: theme.primaryColor,
                            size: 18,
                          ),
                          onPressed: () {
                            setState(() {
                              _activePack = p;
                              _hubMode = HubViewMode.objectGrid;
                              _activeTag = 'ALL';
                              _searchQuery = '';
                            });
                          },
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.redAccent,
                            size: 18,
                          ),
                          onPressed: () => _controller.deletePackage(p.id),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildObjectExplorer(ThemeData theme) {
    final pack = _activePack!;
    final packEntities =
        _controller.entities.where((e) => e.packageId == pack.id).toList();

    final Set<String> tags = {'ALL'};
    for (var o in packEntities) {
      final entTags = _controller.tags.where((t) => t.entityId == o.id);
      for (var t in entTags) {
        tags.add(t.name);
      }
    }

    final filtered = packEntities.where((o) {
      final entTags = _controller.tags.where((t) => t.entityId == o.id);
      final matchText =
          o.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
              o.id.toString().contains(_searchQuery);
      final matchTag =
          _activeTag == 'ALL' || entTags.any((t) => t.name == _activeTag);
      return matchText && matchTag;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(
                Icons.arrow_back_ios,
                size: 14,
                color: Colors.white60,
              ),
              onPressed: () =>
                  setState(() => _hubMode = HubViewMode.packageList),
            ),
            Expanded(
              child: Text(
                pack.name.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Georgia',
                  fontSize: 16,
                  color: Color(0xffe0dcd3),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const Divider(color: Color(0xff1b1b1b), height: 16),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xff0d0d0d),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xff1b1b1b)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.centerLeft,
                child: TextField(
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Search entity logical ID or name...',
                    hintStyle: TextStyle(color: Colors.white24, fontSize: 11),
                  ),
                  onChanged: (val) => setState(() => _searchQuery = val),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(
                Icons.filter_list_sharp,
                color: theme.primaryColor,
                size: 20,
              ),
              onPressed: () => _showFilterBottomSheet(tags.toList(), theme),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: [
              _tab('CARDS', RenderViewMode.card),
              const SizedBox(width: 6),
              _tab('ICONS GRID', RenderViewMode.icon),
              const SizedBox(width: 6),
              _tab('SHOWCASE', RenderViewMode.showcase),
              const SizedBox(width: 6),
              _tab('PAYLOAD GRID', RenderViewMode.payloadGrid),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: _buildMutatedContent(filtered, theme)),
      ],
    );
  }

  Widget _tab(String label, RenderViewMode mode) {
    final isAct = _renderMode == mode;
    return GestureDetector(
      onTap: () => setState(() => _renderMode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isAct ? const Color(0xff161616) : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isAct ? const Color(0xff1b1b1b) : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Courier',
            fontSize: 9,
            color: isAct ? Colors.white : Colors.white30,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildMutatedContent(List<Entity> objects, ThemeData theme) {
    if (objects.isEmpty) {
      return const Center(
        child: Text(
          'No entity matches the selected filter.',
          style: TextStyle(
            fontFamily: 'Arial',
            color: Colors.white24,
            fontSize: 12,
          ),
        ),
      );
    }

    if (_renderMode == RenderViewMode.payloadGrid) {
      return _buildPayloadGrid(theme);
    }

    if (_renderMode == RenderViewMode.card) {
      return GridView.builder(
        physics: const BouncingScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.85,
        ),
        itemCount: objects.length,
        itemBuilder: (context, idx) {
          final o = objects[idx];
          final entProps =
              _controller.properties.where((p) => p.entityId == o.id);
          final kind = entProps
              .firstWhere((p) => p.key == 'kind',
                  orElse: () => const EntityProperty(0, 'kind', 'rectangle'))
              .value;
          final entTags = _controller.tags.where((t) => t.entityId == o.id);

          return GestureDetector(
            onTap: () => _openDetailModal(o, theme),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xff0d0d0d),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xff161616)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    o.category.toUpperCase(),
                    style: TextStyle(
                      fontFamily: 'Arial',
                      fontSize: 8,
                      color: theme.primaryColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    o.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Georgia',
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Kind: ${kind.toUpperCase()}',
                    style: const TextStyle(
                      fontFamily: 'Courier',
                      color: Colors.white30,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: entTags.map((t) {
                        return Container(
                          margin: const EdgeInsets.only(right: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xff161616),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            t.name,
                            style: const TextStyle(
                              fontFamily: 'Arial',
                              color: Colors.white60,
                              fontSize: 8,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    } else if (_renderMode == RenderViewMode.icon) {
      return GridView.builder(
        physics: const BouncingScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
        ),
        itemCount: objects.length,
        itemBuilder: (context, idx) {
          final o = objects[idx];
          return GestureDetector(
            onTap: () => _openDetailModal(o, theme),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xff0d0d0d),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xff161616)),
              ),
              child: const Icon(
                Icons.layers_outlined,
                color: Colors.white24,
                size: 20,
              ),
            ),
          );
        },
      );
    } else {
      return ListView.builder(
        physics: const BouncingScrollPhysics(),
        itemCount: objects.length,
        itemBuilder: (context, idx) {
          final o = objects[idx];
          final entProps =
              _controller.properties.where((p) => p.entityId == o.id);
          final kind = entProps
              .firstWhere((p) => p.key == 'kind',
                  orElse: () => const EntityProperty(0, 'kind', 'rectangle'))
              .value;
          final entTags = _controller.tags.where((t) => t.entityId == o.id);

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: const Color(0xff0d0d0d),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xff161616)),
            ),
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              title: Text(
                o.name,
                style: const TextStyle(
                  fontFamily: 'Georgia',
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                'Type: ${kind.toUpperCase()} • Tags: ${entTags.map((t) => t.name).join(",")}',
                style: const TextStyle(
                  fontFamily: 'Courier',
                  color: Colors.white24,
                  fontSize: 9,
                ),
              ),
              trailing: IconButton(
                icon: const Icon(
                  Icons.open_in_new,
                  size: 16,
                  color: Colors.white38,
                ),
                onPressed: () => _openDetailModal(o, theme),
              ),
            ),
          );
        },
      );
    }
  }

  Widget _buildPayloadGrid(ThemeData theme) {
    final pack = _activePack!;
    final packEntities = _controller.entities
        .where((e) => e.packageId == pack.id)
        .map((e) => e.id)
        .toSet();
    final packPayloads = _controller.payloads
        .where((p) => packEntities.contains(p.entityId))
        .toList();

    if (packPayloads.isEmpty) {
      return const Center(
        child: Text(
          'No payloads configured for this package.',
          style: TextStyle(
            fontFamily: 'Arial',
            color: Colors.white24,
            fontSize: 12,
          ),
        ),
      );
    }

    return GridView.builder(
      physics: const BouncingScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.9,
      ),
      itemCount: packPayloads.length,
      itemBuilder: (context, idx) {
        final payload = packPayloads[idx];
        return FutureBuilder<DecodedPayload>(
          future: const PayloadDecodeService().decodePayload(payload),
          builder: (context, snapshot) {
            final decoded = snapshot.data;
            return Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xff0d0d0d),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xff161616)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xff050505),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: _buildPayloadPreview(decoded),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    payload.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Arial',
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Ver: ${payload.version}',
                    style: const TextStyle(
                      fontFamily: 'Courier',
                      color: Colors.white38,
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPayloadPreview(DecodedPayload? decoded) {
    if (decoded == null) {
      return const Center(
        child: CircularProgressIndicator(
          color: Colors.white24,
          strokeWidth: 2,
        ),
      );
    }

    if (decoded.type == PayloadType.image && decoded.path != null) {
      return Image.file(
        File(decoded.path!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _payloadPlaceholder('Image load failed'),
      );
    }

    if (decoded.type == PayloadType.json) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: SingleChildScrollView(
          child: Text(
            decoded.textPreview ?? '{}',
            style: const TextStyle(
              fontFamily: 'Courier',
              color: Color(0xff00ffcc),
              fontSize: 9,
            ),
          ),
        ),
      );
    }

    if (decoded.type == PayloadType.text) {
      return Padding(
        padding: const EdgeInsets.all(10),
        child: SingleChildScrollView(
          child: Text(
            decoded.textPreview ?? '',
            style: const TextStyle(
              fontFamily: 'Courier',
              color: Colors.white70,
              fontSize: 9,
            ),
          ),
        ),
      );
    }

    return _payloadPlaceholder(decoded.textPreview ?? 'Binary payload');
  }

  Widget _payloadPlaceholder(String label) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file, color: Colors.white24, size: 28),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Courier',
                color: Colors.white38,
                fontSize: 9,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openDetailModal(Entity obj, ThemeData theme) {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          final entProps = _controller.properties
              .where((p) => p.entityId == obj.id)
              .toList();
          final entPayloads =
              _controller.payloads.where((p) => p.entityId == obj.id).toList();

          return Dialog(
            backgroundColor: const Color(0xff0d0d0d),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
              side: const BorderSide(color: Color(0xff1b1b1b)),
            ),
            child: Container(
              padding: const EdgeInsets.all(20),
              constraints: const BoxConstraints(maxWidth: 340),
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      obj.category.toUpperCase(),
                      style: TextStyle(
                        fontFamily: 'Arial',
                        fontSize: 9,
                        color: theme.primaryColor,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      obj.name,
                      style: const TextStyle(
                        fontFamily: 'Georgia',
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      'ABI Pointer: ${obj.id}',
                      style: const TextStyle(
                        fontFamily: 'Courier',
                        fontSize: 11,
                        color: Colors.white24,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const Divider(color: Colors.white10, height: 24),
                    const Text(
                      'TECHNICAL PROPERTIES:',
                      style: TextStyle(
                        fontFamily: 'Arial',
                        fontSize: 9,
                        color: Colors.white24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...entProps.map(
                      (e) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                e.key,
                                style: const TextStyle(
                                  fontFamily: 'Arial',
                                  fontSize: 12,
                                  color: Colors.white38,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              e.value,
                              style: const TextStyle(
                                fontFamily: 'Courier',
                                fontSize: 12,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Divider(color: Colors.white10, height: 20),
                    const Text(
                      'GRAPHICAL BEHAVIOR VARIANTS:',
                      style: TextStyle(
                        fontFamily: 'Arial',
                        fontSize: 9,
                        color: Colors.white24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 65,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        itemCount: entPayloads.length,
                        itemBuilder: (context, sIdx) {
                          final s = entPayloads[sIdx];
                          final isAct = s.id == obj.activePayloadId;
                          return GestureDetector(
                            onTap: () {
                              setModalState(() {
                                _controller.updateEntityActivePayload(
                                    obj.id, s.id);
                              });
                              setState(() {});
                            },
                            child: Container(
                              width: 120,
                              margin:
                                  const EdgeInsets.only(right: 8, bottom: 4),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xff050505),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isAct
                                      ? theme.primaryColor
                                      : const Color(0xff161616),
                                  width: 1.5,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    s.name,
                                    style: const TextStyle(
                                      fontFamily: 'Arial',
                                      fontSize: 10,
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Ver: ${s.version}',
                                    style: const TextStyle(
                                      fontFamily: 'Courier',
                                      fontSize: 8,
                                      color: Colors.white38,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

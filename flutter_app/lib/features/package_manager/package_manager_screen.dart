import 'package:flutter/material.dart';
import 'models.dart';
import 'package_controller.dart';
import 'package_config_screen.dart';

enum HubViewMode { packageList, objectGrid }

enum RenderViewMode { card, icon, showcase }

class PackageManagerPanel extends StatefulWidget {
  const PackageManagerPanel({super.key});

  @override
  State<PackageManagerPanel> createState() => _PackageManagerPanelState();
}

class _PackageManagerPanelState extends State<PackageManagerPanel> {
  final PackageController _controller = PackageController();

  HubViewMode _hubMode = HubViewMode.packageList;
  RenderViewMode _renderMode = RenderViewMode.card;

  MalphasPackage? _activePack;
  String _searchQuery = '';
  String _activeTag = 'ALL';

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Padding(
          padding: const EdgeInsets.only(
            top: 90,
            left: 16,
            right: 16,
            bottom: 95,
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: _hubMode == HubViewMode.packageList
                ? _buildPackageList(theme)
                : _buildObjectExplorer(theme),
          ),
        );
      },
    );
  }

  Widget _buildPackageList(ThemeData theme) {
    final packages = _controller.getAllPackages();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Package Hub', style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  const Text(
                    'Static structures mapped in ../packages/',
                    style: TextStyle(
                      fontFamily: 'Arial',
                      fontSize: 11,
                      color: Colors.white24,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.settings, color: theme.primaryColor, size: 20),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const PackageConfigScreen(),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            itemCount: packages.length,
            itemBuilder: (context, index) {
              final pack = packages[index];
              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xff161616)),
                ),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  title: Text(
                    pack.name,
                    style: const TextStyle(
                      fontFamily: 'Arial',
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '${pack.version} • ${pack.author}\n${pack.description}',
                      style: const TextStyle(
                        fontFamily: 'Arial',
                        fontSize: 11,
                        color: Colors.white38,
                        height: 1.35,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  trailing: const Icon(
                    Icons.arrow_forward_ios,
                    size: 12,
                    color: Colors.white24,
                  ),
                  onTap: () => setState(() {
                    _activePack = pack;
                    _hubMode = HubViewMode.objectGrid;
                  }),
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
    final Set<String> tags = {'ALL'};
    for (var o in pack.objects) {
      for (var t in o.tags) {
        tags.add(t.name);
      }
    }

    final filtered = pack.objects.where((o) {
      final matchText =
          o.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
              o.id.toLowerCase().contains(_searchQuery.toLowerCase());
      final matchTag =
          _activeTag == 'ALL' || o.tags.any((t) => t.name == _activeTag);
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pack.name,
                    style: const TextStyle(
                      fontFamily: 'Georgia',
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Color(0xffe0dcd3),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${pack.version} • ${filtered.length} Blocks Detected',
                    style: const TextStyle(
                      fontFamily: 'Arial',
                      fontSize: 11,
                      color: Colors.white24,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.settings, color: theme.primaryColor, size: 20),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const PackageConfigScreen(),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xff0d0d0d),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xff1b1b1b)),
                ),
                child: TextField(
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontFamily: 'Arial',
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Search by ID or Name...',
                    hintStyle: TextStyle(color: Colors.white24, fontSize: 12),
                    border: InputBorder.none,
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
              onPressed: () => _showFilterBottomSheet(tags, theme),
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
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: _buildMutatedContent(filtered, theme)),
      ],
    );
  }

  Widget _buildMutatedContent(List<MalphasObject> objects, ThemeData theme) {
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
          final obj = objects[idx];
          return GestureDetector(
            onTap: () => _openDetailModal(obj, theme),
            child: Container(
              decoration: BoxDecoration(
                color: theme.cardColor,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xff161616)),
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    obj.category.toUpperCase(),
                    style: TextStyle(
                      fontFamily: 'Arial',
                      fontSize: 8,
                      color: theme.primaryColor,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    obj.name,
                    style: const TextStyle(
                      fontFamily: 'Arial',
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'ID: ${obj.id}',
                    style: const TextStyle(
                      fontFamily: 'Courier',
                      fontSize: 10,
                      color: Colors.white24,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: obj.tags
                        .take(2)
                        .map(
                          (t) => Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white10,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              t.name,
                              style: const TextStyle(
                                fontSize: 8,
                                color: Colors.white60,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    if (_renderMode == RenderViewMode.icon) {
      return GridView.builder(
        physics: const BouncingScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1,
        ),
        itemCount: objects.length,
        itemBuilder: (context, index) => GestureDetector(
          onTap: () => _openDetailModal(objects[index], theme),
          child: Container(
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xff1b1b1b)),
            ),
            child: Center(
              child: Icon(
                Icons.bento_outlined,
                color: theme.primaryColor.withValues(alpha: 0.2),
                size: 22,
              ),
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      itemCount: objects.length,
      itemBuilder: (context, index) {
        final obj = objects[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xff141414)),
          ),
          child: ListTile(
            title: Text(
              obj.name,
              style: const TextStyle(
                fontFamily: 'Arial',
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              'Pointer ID: ${obj.id}',
              style: const TextStyle(
                fontFamily: 'Courier',
                fontSize: 10,
                color: Colors.white24,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Icon(
              Icons.unfold_more_sharp,
              size: 14,
              color: theme.primaryColor,
            ),
            onTap: () => _openDetailModal(obj, theme),
          ),
        );
      },
    );
  }

  void _showFilterBottomSheet(Set<String> tags, ThemeData theme) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xff0d0d0d),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        side: BorderSide(color: Color(0xff1b1b1b)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'FILTER BY TAG COVERAGE',
                  style: TextStyle(
                    fontFamily: 'Arial',
                    fontSize: 10,
                    color: Colors.white38,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: tags.map((t) {
                    final isSel = _activeTag == t;
                    return GestureDetector(
                      onTap: () {
                        setState(() => _activeTag = t);
                        Navigator.pop(context);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isSel
                              ? theme.primaryColor
                              : const Color(0xff161616),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          t.toUpperCase(),
                          style: TextStyle(
                            fontFamily: 'Arial',
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: isSel ? Colors.black : Colors.white,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openDetailModal(MalphasObject obj, ThemeData theme) {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Dialog(
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
                  ...obj.properties.entries.map(
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
                      itemCount: obj.skins.length,
                      itemBuilder: (context, sIdx) {
                        final s = obj.skins[sIdx];
                        final isAct = sIdx == obj.activeSkinIndex;
                        return GestureDetector(
                          onTap: () {
                            setModalState(() => obj.activeSkinIndex = sIdx);
                            setState(() {});
                          },
                          child: Container(
                            width: 120,
                            margin: const EdgeInsets.only(right: 8, bottom: 4),
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
                                Text(
                                  'v${s.version}',
                                  style: const TextStyle(
                                    fontFamily: 'Courier',
                                    fontSize: 8,
                                    color: Colors.white24,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      child: const Text(
                        'CLOSE',
                        style: TextStyle(
                          fontFamily: 'Arial',
                          color: Color(0xffe0dcd3),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tab(String label, RenderViewMode mode) {
    final isSel = _renderMode == mode;
    return GestureDetector(
      onTap: () => setState(() => _renderMode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isSel ? const Color(0xff0d0d0d) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSel ? const Color(0xff1b1b1b) : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Arial',
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: isSel ? const Color(0xffe0dcd3) : Colors.white24,
          ),
        ),
      ),
    );
  }
}

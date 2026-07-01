import 'package:flutter/material.dart';
import '../../core/models/flat_models.dart';
import '../../core/state/entity_store.dart';

class FolderTreeScreen extends StatefulWidget {
  const FolderTreeScreen({super.key});

  @override
  State<FolderTreeScreen> createState() => _FolderTreeScreenState();
}

class _FolderTreeScreenState extends State<FolderTreeScreen> {
  final EntityStore _store = EntityStore();
  final Set<String> _activeTags = <String>{};
  final TextEditingController _tagController = TextEditingController();

  @override
  void dispose() {
    _tagController.dispose();
    super.dispose();
  }

  int get _filterMask {
    if (_activeTags.isEmpty) return 0;
    int mask = 0;
    for (final tag in _store.tags) {
      if (_activeTags.contains(tag.name)) {
        mask |= tag.bitmask;
      }
    }
    return mask;
  }

  List<int> get _filteredEntityIds {
    final mask = _filterMask;
    return _store.filterByTagMask(mask);
  }

  Set<String> get _availableTags {
    return _store.tags.map((t) => t.name).toSet();
  }

  void _toggleTag(String tag) {
    setState(() {
      if (_activeTags.contains(tag)) {
        _activeTags.remove(tag);
      } else {
        _activeTags.add(tag);
      }
    });
  }

  void _addTag() {
    final name = _tagController.text.trim();
    if (name.isEmpty) return;
    final bit = _nextBit();
    _store.addTag(EntityTag(entityId: 0, name: name, bitmask: bit));
    _tagController.clear();
    setState(() {});
  }

  int _nextBit() {
    int mask = 0;
    for (final tag in _store.tags) {
      mask |= tag.bitmask;
    }
    if (mask == 0) return 1;
    for (int i = 0; i < 64; i++) {
      final bit = 1 << i;
      if ((mask & bit) == 0) return bit;
    }
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    final tags = _availableTags.toList()..sort();
    final entityIds = _filteredEntityIds;

    return Scaffold(
      backgroundColor: const Color(0xff050505),
      appBar: AppBar(
        backgroundColor: const Color(0xff0d0d0d),
        title: const Text('FOLDERS & TAGS',
            style: TextStyle(
                fontFamily: 'Courier',
                fontSize: 12,
                fontWeight: FontWeight.bold)),
      ),
      body: Column(
        children: [
          _buildTagEditor(tags),
          Expanded(
            child: entityIds.isEmpty
                ? const Center(
                    child: Text(
                      'No entities match the selected tags.',
                      style: TextStyle(
                        fontFamily: 'Arial',
                        color: Colors.white24,
                        fontSize: 12,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: entityIds.length,
                    itemBuilder: (context, index) {
                      final entity = _store.getEntity(entityIds[index]);
                      if (entity == null) return const SizedBox.shrink();
                      return _EntityListTile(
                        entity: entity,
                        tags: _store.tags
                            .where((t) => t.entityId == entity.id)
                            .map((t) => t.name)
                            .toList(),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTagEditor(List<String> tags) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Color(0xff0d0d0d),
        border: Border(bottom: BorderSide(color: Color(0xff161616))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _tagController,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'New tag...',
                    hintStyle:
                        const TextStyle(color: Colors.white24, fontSize: 12),
                    filled: true,
                    fillColor: const Color(0xff161616),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _addTag(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _addTag,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xff00ffcc),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                child: const Text('ADD',
                    style: TextStyle(fontFamily: 'Courier', fontSize: 10)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: tags.map((tag) {
              final isActive = _activeTags.contains(tag);
              return FilterChip(
                label: Text(tag,
                    style: TextStyle(
                        fontFamily: 'Arial',
                        fontSize: 10,
                        color: isActive ? Colors.black : Colors.white70)),
                selected: isActive,
                selectedColor: const Color(0xff00ffcc),
                backgroundColor: const Color(0xff161616),
                checkmarkColor: Colors.black,
                onSelected: (_) => _toggleTag(tag),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _EntityListTile extends StatelessWidget {
  final Entity entity;
  final List<String> tags;

  const _EntityListTile({required this.entity, required this.tags});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xff0d0d0d),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xff161616)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entity.name.isNotEmpty ? entity.name : 'Entity ${entity.id}',
            style: const TextStyle(
              fontFamily: 'Georgia',
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'ID: ${entity.id} • ${entity.category}',
            style: const TextStyle(
              fontFamily: 'Courier',
              color: Colors.white38,
              fontSize: 9,
            ),
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: tags
                  .map((t) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xff161616),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          t,
                          style: const TextStyle(
                            fontFamily: 'Arial',
                            color: Colors.white60,
                            fontSize: 8,
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

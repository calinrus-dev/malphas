import 'package:flutter/material.dart';

class PackageManagerScreen extends StatelessWidget {
  const PackageManagerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'Package Hub',
          style: TextStyle(
            fontFamily: 'Georgia',
            fontSize: 20,
            color: Color(0xffe0dcd3),
          ),
        ),
        backgroundColor: Colors.black,
        elevation: 0,
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 1.2,
        ),
        itemCount: 2,
        itemBuilder: (context, index) {
          final titles = ['Mecatron Kanji Pack', 'Sprites 2D Retro'];
          return Container(
            decoration: BoxDecoration(
              color: const Color(0xff0d0d0d),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xff161616)),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  titles[index],
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Colors.white,
                  ),
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: const [
                    Chip(
                      label: Text(
                        'JA',
                        style: TextStyle(fontSize: 10, color: Colors.white60),
                      ),
                      backgroundColor: Colors.white10,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    Chip(
                      label: Text(
                        'Vulkan',
                        style: TextStyle(fontSize: 10, color: Colors.white60),
                      ),
                      backgroundColor: Colors.white10,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

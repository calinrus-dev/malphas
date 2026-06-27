import 'package:flutter/material.dart';

class EngineManagerScreen extends StatelessWidget {
  const EngineManagerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'Engine Depot',
          style: TextStyle(
            fontFamily: 'Georgia',
            fontSize: 20,
            color: Color(0xffe0dcd3),
          ),
        ),
        backgroundColor: Colors.black,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: const Color(0xff0d0d0d),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xff161616)),
            ),
            child: const ListTile(
              contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              title: Text(
                'LIQUID Core v1.0',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  fontSize: 15,
                ),
              ),
              subtitle: Text(
                'Hash: 0xDEADBEEF | Schema Verified',
                style: TextStyle(color: Colors.white30, fontSize: 12),
              ),
              trailing: Switch(
                value: true,
                onChanged: null,
                activeColor: Color(0xffe0dcd3),
                activeTrackColor: Colors.white12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

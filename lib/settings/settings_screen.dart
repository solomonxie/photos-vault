import 'package:flutter/material.dart';

import '../widgets/placeholder_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: const PlaceholderScreen(
        icon: Icons.settings_outlined,
        title: 'AWS Settings',
        note:
            'Access key, secret, region, bucket, prefix (flutter_secure_storage-backed) land in T1.2.',
      ),
    );
  }
}

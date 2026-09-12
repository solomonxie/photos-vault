import 'package:flutter/material.dart';

import '../widgets/placeholder_screen.dart';

class BackupScreen extends StatelessWidget {
  const BackupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup')),
      body: const PlaceholderScreen(
        icon: Icons.cloud_upload_outlined,
        title: 'Nothing Backed Up Yet',
        note: 'The upload dashboard (queued/uploading/done/failed) lands in T4.3.',
      ),
    );
  }
}

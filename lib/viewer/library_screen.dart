import 'package:flutter/material.dart';

import '../widgets/placeholder_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Library')),
      body: const PlaceholderScreen(
        icon: Icons.photo_library_outlined,
        title: 'No Photos Yet',
        note: 'The photo_manager-backed thumbnail grid lands in T4.1.',
      ),
    );
  }
}

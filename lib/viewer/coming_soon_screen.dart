import 'package:flutter/cupertino.dart';

/// Placeholder detail screen for smart collections not implemented yet
/// (People/Places/Events) — see IMPLEMENTATION_PLAN.md T4.4.
class ComingSoonScreen extends StatelessWidget {
  const ComingSoonScreen({super.key, required this.title, required this.body, required this.icon});

  final String title;
  final String body;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(title)),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 56, color: CupertinoColors.systemGrey),
                const SizedBox(height: 12),
                Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(body, textAlign: TextAlign.center, style: const TextStyle(color: CupertinoColors.systemGrey)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

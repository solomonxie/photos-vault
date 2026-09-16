import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../settings/settings_section.dart';

/// The two things anyone wants to do with demo content, with enough text to
/// say what each one touches.
///
/// It's a page rather than a single "Reset Demo Data" row because the row
/// was one verb doing two jobs — it added missing demo items *and* was the
/// only way to get them back after deleting them, while nothing offered to
/// take them away again. Adding sample photos to a real library is easy to
/// do by accident and was, until now, tedious to undo.
class DemoDataScreen extends StatefulWidget {
  const DemoDataScreen({
    super.key,
    required this.onAdd,
    required this.onRemove,
  });

  /// Adds anything missing; already-present demo items are left alone.
  final Future<void> Function() onAdd;

  /// Returns how many demo photos were taken back out.
  final Future<int> Function() onRemove;

  @override
  State<DemoDataScreen> createState() => _DemoDataScreenState();
}

class _DemoDataScreenState extends State<DemoDataScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRemove(AppLocalizations l10n) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.demoDataRemoveTitle),
        content: Text(l10n.demoDataRemoveBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(widget.onRemove);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(l10n.demoDataTitle),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 16, bottom: 32),
          children: [
            SettingsSection(
              heading: l10n.demoDataTitle,
              hint: l10n.demoDataHint,
              children: [
                _ActionRow(
                  title: l10n.demoDataAddAction,
                  description: l10n.demoDataAddDescription,
                  onTap: _busy ? null : () => _run(widget.onAdd),
                ),
                const SettingsHairline(indent: settingsPagePadding),
                _ActionRow(
                  title: l10n.demoDataRemoveAction,
                  description: l10n.demoDataRemoveDescription,
                  destructive: true,
                  onTap: _busy ? null : () => _confirmRemove(l10n),
                ),
              ],
              footer: _busy
                  ? SettingsFooterLine(text: l10n.demoDataWorking, busy: true)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.title,
    required this.description,
    required this.onTap,
    this.destructive = false,
  });

  final String title;
  final String description;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: settingsPagePadding,
          vertical: 12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: !enabled
                    ? settingsTertiary
                    : destructive
                    ? CupertinoColors.systemRed
                    : settingsAccent,
              ),
            ),
            const SizedBox(height: 4),
            Text(description, style: settingsHintStyle),
          ],
        ),
      ),
    );
  }
}

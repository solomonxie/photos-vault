import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';

/// "Removed X · Undo" along the bottom for five seconds, one at a time.
/// The owner calls [dispose] so a timer never fires into a closed page.
class UndoToast {
  Timer? _timer;
  OverlayEntry? _entry;

  void show(
    BuildContext context,
    String message,
    Future<void> Function() undo,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final overlay = Overlay.of(context);
    dispose();
    late final OverlayEntry entry;
    void close() {
      if (!identical(_entry, entry)) return;
      dispose();
    }

    entry = OverlayEntry(
      builder: (context) => Positioned(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).padding.bottom + 24,
        child: CupertinoPopupSurface(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                CupertinoButton(
                  key: const ValueKey('undoToastUndo'),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: Size.zero,
                  onPressed: () {
                    close();
                    unawaited(undo());
                  },
                  child: Text(l10n.actionUndo),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    _entry = entry;
    _timer = Timer(const Duration(seconds: 5), close);
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}

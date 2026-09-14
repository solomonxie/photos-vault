import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/private_album.dart';
import '../storage/private_album_store.dart';
import 'private_album_screen.dart';

/// What the user picked in [showPrivateAlbumPasscodeSheet].
class PrivateAlbumChoice {
  const PrivateAlbumChoice({required this.passcode, required this.createNew});

  final String passcode;

  /// `true` for "Create New", `false` for "Enter" — see DESIGN.md: both
  /// resolve to the same album when the passcode already exists; they only
  /// differ when it doesn't (Enter shows an empty, not-yet-persisted album;
  /// Create New persists one right away).
  final bool createNew;
}

/// The Utilities "Hidden" row's passcode popup: a 4-digit numeric keypad
/// (no system keyboard — tap 4 digits directly) plus "Enter"/"Create New"
/// buttons. No distinct "wrong passcode" state — any 4 digits are valid
/// input, resolved by the caller against [PrivateAlbumStore].
Future<PrivateAlbumChoice?> showPrivateAlbumPasscodeSheet(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  var passcode = '';
  return showCupertinoDialog<PrivateAlbumChoice>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final valid = passcode.length == 4;
        return CupertinoAlertDialog(
          title: Text(l10n.privateAlbumGateTitle),
          content: Column(
            children: [
              const SizedBox(height: 8),
              Text(l10n.privateAlbumGateBody),
              const SizedBox(height: 16),
              _PasscodeDots(length: passcode.length),
              const SizedBox(height: 12),
              _PasscodeKeypad(
                onDigit: (digit) {
                  if (passcode.length >= 4) return;
                  setState(() => passcode += digit);
                },
                onBackspace: passcode.isEmpty
                    ? null
                    : () => setState(() => passcode = passcode.substring(0, passcode.length - 1)),
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.actionCancel)),
            CupertinoDialogAction(
              onPressed: valid ? () => Navigator.of(context).pop(PrivateAlbumChoice(passcode: passcode, createNew: false)) : null,
              child: Text(l10n.privateAlbumEnterButton),
            ),
            CupertinoDialogAction(
              onPressed: valid ? () => Navigator.of(context).pop(PrivateAlbumChoice(passcode: passcode, createNew: true)) : null,
              child: Text(l10n.privateAlbumCreateButton),
            ),
          ],
        );
      },
    ),
  );
}

/// Four dots, filled left-to-right as digits are entered — same affordance
/// as iOS' own passcode screens, standing in for the text field's cursor.
class _PasscodeDots extends StatelessWidget {
  const _PasscodeDots({required this.length});

  final int length;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      for (var i = 0; i < 4; i++)
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 7),
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i < length
                ? CupertinoDynamicColor.resolve(CupertinoColors.label, context)
                : CupertinoDynamicColor.resolve(CupertinoColors.systemGrey4, context),
          ),
        ),
    ],
  );
}

/// 1-9-0 numeric keypad, tap-only — no system keyboard ever pops up.
class _PasscodeKeypad extends StatelessWidget {
  const _PasscodeKeypad({required this.onDigit, required this.onBackspace});

  final ValueChanged<String> onDigit;
  final VoidCallback? onBackspace;

  static const _rows = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
  ];

  Widget _key(BuildContext context, {String? label, IconData? icon, VoidCallback? onPressed}) => SizedBox(
    width: 60,
    height: 44,
    child: CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      child: icon != null
          ? Icon(icon, size: 20)
          : Text(label!, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500)),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final row in _rows)
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [for (final digit in row) _key(context, label: digit, onPressed: () => onDigit(digit))],
        ),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(width: 60, height: 44),
          _key(context, label: '0', onPressed: () => onDigit('0')),
          _key(context, icon: CupertinoIcons.delete_left, onPressed: onBackspace),
        ],
      ),
    ],
  );
}

/// Utilities' "Hidden" row: prompts for a passcode, then opens the album at
/// it — existing or (on "Enter") a fresh, not-yet-persisted empty one.
Future<void> openPrivateAlbums(
  BuildContext context, {
  required AssetRecordStore assetRecordStore,
  required PrivateAlbumStore privateAlbumStore,
}) async {
  final choice = await showPrivateAlbumPasscodeSheet(context);
  if (choice == null || !context.mounted) return;
  final album = choice.createNew
      ? await privateAlbumStore.ensure(choice.passcode)
      : await privateAlbumStore.find(choice.passcode) ??
            PrivateAlbum(id: PrivateAlbumStore.hashOf(choice.passcode), createdAt: DateTime.now());
  if (!context.mounted) return;
  await Navigator.of(context).push(
    CupertinoPageRoute(
      builder: (_) =>
          PrivateAlbumScreen(album: album, assetRecordStore: assetRecordStore, privateAlbumStore: privateAlbumStore),
    ),
  );
}

/// The grid tiles' long-press "Hide" action: same passcode popup, then moves
/// (not copies) `record` straight into whichever album is chosen, lazily
/// creating it if needed. Either button works the same way here — the
/// Enter-vs-Create-New distinction only matters when just *viewing* an
/// album that might not exist yet. Returns `false` (no-op) if the popup was
/// cancelled — callers that optimistically update local state should check
/// this rather than assume the hide happened.
Future<bool> hideIntoPrivateAlbum(
  BuildContext context, {
  required AssetRecordStore assetRecordStore,
  required PrivateAlbumStore privateAlbumStore,
  required AssetRecord record,
}) async {
  final choice = await showPrivateAlbumPasscodeSheet(context);
  if (choice == null) return false;
  final album = await privateAlbumStore.ensure(choice.passcode);
  await assetRecordStore.setHidden(record.localId, true);
  await privateAlbumStore.addAssets(album.id, [record.localId], moved: true);
  return true;
}

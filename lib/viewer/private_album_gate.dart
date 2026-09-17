import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/library_custody.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/passcode_hash.dart';
import 'private_album_screen.dart';

/// The Utilities "Hidden" row's passcode popup: a 4-digit numeric keypad
/// (no system keyboard) — the 4th digit submits automatically, no
/// Enter/Create/Cancel buttons. There's nothing to distinguish "enter" from
/// "create": the group of assets sharing this passcode's hash *is* the
/// album (see `AssetRecord.passcodeHash`), whether or not anything's in it
/// yet. Pops with the raw passcode, or `null` if backed out via the "x".
Future<String?> showPrivateAlbumPasscodeSheet(
  BuildContext context, {
  String? note,
}) {
  final l10n = AppLocalizations.of(context)!;
  var passcode = '';
  return showCupertinoDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        return CupertinoAlertDialog(
          title: Text(l10n.privateAlbumGateTitle),
          content: Column(
            children: [
              const SizedBox(height: 8),
              Text(l10n.privateAlbumGateBody),
              if (note != null) ...[
                const SizedBox(height: 8),
                Text(
                  note,
                  style: const TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.systemGrey,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _PasscodeDots(length: passcode.length),
              const SizedBox(height: 12),
              _PasscodeKeypad(
                onDigit: (digit) {
                  if (passcode.length >= 4) return;
                  final next = passcode + digit;
                  setState(() => passcode = next);
                  if (next.length == 4) Navigator.of(context).pop(next);
                },
                onBackspace: passcode.isEmpty
                    ? null
                    : () => setState(
                        () => passcode = passcode.substring(
                          0,
                          passcode.length - 1,
                        ),
                      ),
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.actionCancel),
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
                : CupertinoDynamicColor.resolve(
                    CupertinoColors.systemGrey4,
                    context,
                  ),
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

  Widget _key(
    BuildContext context, {
    String? label,
    IconData? icon,
    VoidCallback? onPressed,
  }) => SizedBox(
    width: 60,
    height: 44,
    child: CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      child: icon != null
          ? Icon(icon, size: 20)
          : Text(
              label!,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
            ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final row in _rows)
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final digit in row)
              _key(context, label: digit, onPressed: () => onDigit(digit)),
          ],
        ),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(width: 60, height: 44),
          _key(context, label: '0', onPressed: () => onDigit('0')),
          _key(
            context,
            icon: CupertinoIcons.delete_left,
            onPressed: onBackspace,
          ),
        ],
      ),
    ],
  );
}

/// Utilities' "Hidden" row: prompts for a passcode, then opens whatever's
/// currently tagged with its hash — an empty list if nothing is.
Future<void> openPrivateAlbums(
  BuildContext context, {
  required AssetRecordStore assetRecordStore,
  LibraryCustody? custody,
}) async {
  final passcode = await showPrivateAlbumPasscodeSheet(context);
  if (passcode == null || !context.mounted) return;
  await Navigator.of(context).push(
    CupertinoPageRoute(
      builder: (_) => PrivateAlbumScreen(
        passcodeHash: hashPasscode(passcode),
        assetRecordStore: assetRecordStore,
        custody: custody,
      ),
    ),
  );
}

/// Hides [records]: tags each with a passcode hash — no separate album to
/// create first, the group sharing a hash *is* the album — and takes them
/// out of the OS photo library, which is the half that makes "hidden" mean
/// anything. Returns `false` (no-op) if the passcode popup was cancelled.
///
/// Both halves live here rather than at the call sites. They were split
/// once, with the library grid doing the taking-out and the three other
/// ways into a hidden album doing only the tagging — so a photo added from
/// inside the album disappeared from this app and stayed in Photos, which
/// is the one outcome a hidden album must not produce.
///
/// [passcodeHash] is for a hidden album that's already open: it knows its
/// own hash, and asking for it again to add to it would be asking a
/// question already answered.
Future<bool> hideIntoPrivateAlbum(
  BuildContext context, {
  required AssetRecordStore assetRecordStore,
  required List<AssetRecord> records,
  String? passcodeHash,
  LibraryCustody? custody,
}) async {
  final l10n = AppLocalizations.of(context)!;
  // Asked every time, before anything moves. Hiding deletes the originals
  // out of Photos — a destructive, one-way step that this app is the only
  // holder of afterwards — and a step like that is confirmed at the point
  // of action, not explained in a note beside a keypad.
  final confirmed = await showCupertinoDialog<bool>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      title: Text(l10n.libraryHideConfirmTitle(records.length)),
      content: Text(l10n.libraryHideConfirmBody),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.actionCancel),
        ),
        CupertinoDialogAction(
          isDestructiveAction: true,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.libraryHideConfirmAction),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  var hash = passcodeHash;
  if (hash == null) {
    final passcode = await showPrivateAlbumPasscodeSheet(context);
    if (passcode == null) return false;
    hash = hashPasscode(passcode);
  }
  final keeper = custody ?? LibraryCustody(store: assetRecordStore);
  var stillInLibrary = 0;
  var failed = 0;
  for (final record in records) {
    await assetRecordStore.setPasscodeHash(record.localId, hash);
    switch (await keeper.takeOut(record)) {
      case CustodyResult.failed:
        // Nothing was copied out, so nothing should have been hidden
        // either — a hidden photo this app doesn't hold is a photo nobody
        // holds.
        await assetRecordStore.setPasscodeHash(record.localId, null);
        failed++;
      case CustodyResult.takenButStillInLibrary:
        stillInLibrary++;
      case CustodyResult.taken || CustodyResult.returned:
        break;
    }
  }
  if (context.mounted && (failed > 0 || stillInLibrary > 0)) {
    await showCupertinoDialog<void>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        content: Text(
          failed > 0 ? l10n.libraryHideFailed : l10n.libraryHideStillInPhotos,
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.actionOk),
          ),
        ],
      ),
    );
  }
  return failed < records.length;
}

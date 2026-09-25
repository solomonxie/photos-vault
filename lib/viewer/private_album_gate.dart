import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/library_custody.dart';
import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/passcode_hash.dart';
import '../vault/keys.dart';
import '../vault/passphrase_sheet.dart';
import '../upload/pending_deletes.dart';
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
  // A sheet, not an alert. An alert is about 270 points wide whatever the
  // phone, and three keys across that leaves 60-point targets with no gaps
  // — small enough that the digit you hit isn't reliably the one you meant.
  // A sheet is as wide as the screen, which is where the room comes from.
  return showCupertinoModalPopup<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1C1C1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 5,
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGrey,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                l10n.privateAlbumGateTitle,
                style: const TextStyle(
                  color: CupertinoColors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  note ?? l10n.privateAlbumGateBody,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.systemGrey,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              _PasscodeDots(length: passcode.length),
              const SizedBox(height: 26),
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
              const SizedBox(height: 8),
              CupertinoButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.actionCancel),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
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
          margin: const EdgeInsets.symmetric(horizontal: 9),
          width: 15,
          height: 15,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: i < length ? CupertinoColors.white : null,
            border: Border.all(color: CupertinoColors.systemGrey, width: 1.5),
          ),
        ),
    ],
  );
}

/// 1-9-0 numeric keypad, tap-only — no system keyboard ever pops up.
///
/// Round, filled keys sized off the sheet's own width, the way the lock
/// screen's are: a passcode is typed without looking, so each key has to be
/// findable by where it is rather than by aiming at it. The circle isn't
/// decoration — it's the target, drawn where the target actually is.
class _PasscodeKeypad extends StatelessWidget {
  const _PasscodeKeypad({required this.onDigit, required this.onBackspace});

  final ValueChanged<String> onDigit;
  final VoidCallback? onBackspace;

  static const _rows = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
  ];

  /// Gap between keys, and the most a key will grow to. Bigger than this
  /// and a thumb has to travel across the phone to reach the far column.
  static const _gap = 22.0;
  static const _maxKey = 78.0;

  Widget _key(
    double size, {
    String? label,
    IconData? icon,
    VoidCallback? onPressed,
  }) => SizedBox(
    width: size,
    height: size,
    child: CupertinoButton(
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(size / 2),
      // The digits sit on a face; backspace is bare, because it isn't one
      // of the ten and shouldn't look like it.
      color: icon == null ? const Color(0xFF3A3A3C) : null,
      onPressed: onPressed,
      child: icon != null
          ? Icon(icon, size: 26, color: CupertinoColors.white)
          : Text(
              label!,
              style: TextStyle(
                fontSize: size * 0.42,
                fontWeight: FontWeight.w400,
                color: CupertinoColors.white,
              ),
            ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.maxWidth.clamp(0.0, 420.0);
      final size = ((available - _gap * 4) / 3).clamp(56.0, _maxKey);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in _rows) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final digit in row)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: _gap / 2),
                    child: _key(
                      size,
                      label: digit,
                      onPressed: () => onDigit(digit),
                    ),
                  ),
              ],
            ),
            SizedBox(height: _gap * 0.6),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(width: size + _gap),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: _gap / 2),
                child: _key(size, label: '0', onPressed: () => onDigit('0')),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: _gap / 2),
                child: _key(
                  size,
                  icon: CupertinoIcons.delete_left,
                  onPressed: onBackspace,
                ),
              ),
            ],
          ),
        ],
      );
    },
  );
}

/// Utilities' "Hidden" row: prompts for a passcode, then opens whatever's
/// currently tagged with its hash — an empty list if nothing is.
Future<void> openPrivateAlbums(
  BuildContext context, {
  required AssetRecordStore assetRecordStore,
  LibraryCustody? custody,
  VaultKeys? vaultKeys,
}) async {
  final keys = vaultKeys ?? VaultKeys();
  // Set up at the moment it first matters, rather than behind a switch in
  // Settings. A switch reading "Hidden - ON" answers, to anyone holding the
  // phone, the one question this whole thing exists not to answer.
  if ((await keys.entries()).isEmpty) {
    if (!context.mounted) return;
    if (await showVaultSetupSheet(context, keys: keys) == null) return;
  }
  if (!context.mounted) return;
  final passcode = await showPrivateAlbumPasscodeSheet(context);
  if (passcode == null) return;
  // Fills the key ring for this session, so the upload path can find this
  // album's key by the hash the records carry without ever holding the
  // digits itself. Dropped when the app dies.
  final album = await keys.unlockAlbum(passcode);
  if (!context.mounted) return;
  await Navigator.of(context).push(
    CupertinoPageRoute(
      builder: (_) => PrivateAlbumScreen(
        passcodeHash: hashPasscode(passcode),
        assetRecordStore: assetRecordStore,
        custody: custody,
        albumKeys: album,
        vaultKeys: keys,
      ),
    ),
  );
}

/// Hides [records]: tags each with a passcode hash — no separate album to
/// create first, the group sharing a hash *is* the album — and takes them
/// Queues every object this record already has in every bucket for
/// deletion, and forgets that they were ever uploaded, so the next sync
/// treats the photo as new. The deletion itself is durable rather than
/// attempted here: hiding happens offline all the time, and a delete that
/// quietly failed would leave a plain copy in the bucket forever.
Future<void> _retractFromBuckets({
  required AssetRecord record,
  required AssetRecordStore store,
  required PendingDeletes deletes,
  required BackupTargetsStore targetsStore,
}) async {
  final targets = await targetsStore.loadAll();
  // The per-target rows go with the aggregate status below. Left behind,
  // the next sync would read them as "every target already has this" and
  // upload nothing, for a photo whose plain copies were just retracted.
  await store.forgetUploads(record.localId);
  final tasks = <PendingDelete>[];
  for (final kind in DerivativeKind.values) {
    final key = record.stateOf(kind).destinationKey;
    if (key == null) continue;
    for (final target in targets) {
      tasks.add(PendingDelete(objectKey: key, targetId: target.id));
    }
    await store.updateDerivative(
      record.localId,
      kind,
      const DerivativeState(status: UploadStatus.pending),
    );
  }
  if (tasks.isNotEmpty) await deletes.add(tasks);
}

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
  PendingDeletes? pendingDeletes,
  BackupTargetsStore? targetsStore,
}) async {
  final l10n = AppLocalizations.of(context)!;
  // No confirmation of our own. The OS puts one up for the delete a moment
  // later — listing exactly what is about to go — and two dialogs in a row
  // asking the same question is how people learn to tap through both.
  var hash = passcodeHash;
  if (hash == null) {
    final passcode = await showPrivateAlbumPasscodeSheet(context);
    if (passcode == null) return false;
    hash = hashPasscode(passcode);
  }
  final keeper = custody ?? LibraryCustody(store: assetRecordStore);
  for (final record in records) {
    await assetRecordStore.setPasscodeHash(record.localId, hash);
  }
  final results = await keeper.takeOutMany(records);

  var stillInLibrary = 0;
  var failed = 0;
  for (final record in records) {
    switch (results[record.localId] ?? CustodyResult.failed) {
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
    // Whatever is already in the bucket was uploaded in the clear, under
    // this photo's own name. Hiding has to take it back out, or the
    // private album's copy sits beside a plain one that predates it.
    await _retractFromBuckets(
      record: record,
      store: assetRecordStore,
      deletes: pendingDeletes ?? PendingDeletes(store: assetRecordStore),
      targetsStore: targetsStore ?? BackupTargetsStore(),
    );
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

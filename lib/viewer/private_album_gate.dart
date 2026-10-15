import 'dart:async';
import 'dart:isolate';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/library_custody.dart';
import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/passcode_hash.dart';
import '../upload/original_restore.dart';
import '../vault/hidden_transition.dart';
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
  String? title,
  String? warning,
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
          // Scrolls only when it must: the hide prompt's warning makes it
          // taller than a small phone's screen.
          child: SingleChildScrollView(
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
                  title ?? l10n.privateAlbumGateTitle,
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
                if (warning != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
                    child: Text(
                      warning,
                      key: const ValueKey('hideCodeWarning'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.systemOrange,
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
    ),
  );
}

/// The code that hiding asks for. Its own kind of prompt, not the one that
/// opens the album: every code opens *an* album, so a mistyped code here
/// hides photos somewhere nobody will ever look. So it says what this code
/// is, warns plainly, and takes it twice. Null if cancelled or the two
/// entries differ.
Future<String?> askHideCode(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final first = await showPrivateAlbumPasscodeSheet(
    context,
    title: l10n.hideCodeTitle,
    note: l10n.hideCodeBody,
    warning: l10n.hideCodeWarning,
  );
  if (first == null || !context.mounted) return null;
  final second = await showPrivateAlbumPasscodeSheet(
    context,
    title: l10n.hideCodeConfirmTitle,
    note: l10n.hideCodeConfirmBody,
    warning: l10n.hideCodeWarning,
  );
  if (second == null) return null;
  if (second == first) return first;
  if (context.mounted) {
    await showCupertinoDialog<void>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        content: Text(l10n.hideCodeMismatch),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.actionOk),
          ),
        ],
      ),
    );
  }
  return null;
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
  }) => _KeypadKey(
    size: size,
    // The gaps belong to the keys: a fast thumb lands between circles as
    // often as on them, and a dead gap swallows the digit.
    reach: const EdgeInsets.symmetric(
      horizontal: _gap / 2,
      vertical: _gap * 0.3,
    ),
    // The digits sit on a face; backspace is bare, because it isn't one
    // of the ten and shouldn't look like it.
    filled: icon == null,
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
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.maxWidth.clamp(0.0, 420.0);
      final size = ((available - _gap * 4) / 3).clamp(56.0, _maxKey);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in _rows)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final digit in row)
                  _key(size, label: digit, onPressed: () => onDigit(digit)),
              ],
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(width: size + _gap),
              _key(size, label: '0', onPressed: () => onDigit('0')),
              _key(
                size,
                icon: CupertinoIcons.delete_left,
                onPressed: onBackspace,
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
/// A person's own hidden folder: an album like any other, whose code is the
/// digits namespaced by the person. The same four digits open a different
/// album per person and a different one again from Utilities, and nothing
/// stored links a person to a hidden photo — only the key derivation does.
String personAlbumCode(String personId, String digits) =>
    'person:$personId:$digits';

/// Whether [personId] has a hidden folder that still holds something. The
/// folder is known only by the hash of its code, so all 10,000 codes are
/// tried — off the UI isolate.
Future<bool> personHasHiddenFolder(
  AssetRecordStore store,
  String personId,
) async {
  final hashes = await store.passcodeHashes();
  if (hashes.isEmpty) return false;
  return Isolate.run(() => _anyPersonCode(personId, hashes));
}

bool _anyPersonCode(String personId, Set<String> hashes) {
  for (var i = 0; i < 10000; i++) {
    final digits = i.toString().padLeft(4, '0');
    if (hashes.contains(hashPasscode(personAlbumCode(personId, digits)))) {
      return true;
    }
  }
  return false;
}

/// [codeFor] turns the typed digits into the album's code — see
/// [personAlbumCode]; [title] names the album screen.
Future<void> openPrivateAlbums(
  BuildContext context, {
  required AssetRecordStore assetRecordStore,
  LibraryCustody? custody,
  VaultKeys? vaultKeys,
  int? libraryCount,
  String Function(String digits)? codeFor,
  String? title,
}) async {
  final keys = vaultKeys ?? VaultKeys();
  // Set up at the moment it first matters, rather than behind a switch in
  // Settings. A switch reading "Hidden - ON" answers, to anyone holding the
  // phone, the one question this whole thing exists not to answer.
  if ((await keys.entries()).isEmpty) {
    if (!context.mounted) return;
    if (libraryCount != null &&
        libraryCount < fewDecoysThreshold &&
        !await _acceptFewDecoys(context)) {
      return;
    }
    if (!context.mounted) return;
    if (await showVaultSetupSheet(context, keys: keys) == null) return;
  }
  if (!context.mounted) return;
  final digits = await showPrivateAlbumPasscodeSheet(context, title: title);
  if (digits == null) return;
  final passcode = codeFor?.call(digits) ?? digits;
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
        title: title,
      ),
    ),
  );
}

/// Below this many photos the decoys repeat and stand out.
const fewDecoysThreshold = 100;

Future<bool> _acceptFewDecoys(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  final ok = await showCupertinoDialog<bool>(
    context: context,
    builder: (dialogContext) => CupertinoAlertDialog(
      title: Text(l10n.privateAlbumFewDecoysTitle),
      content: Text(l10n.privateAlbumFewDecoysBody),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.actionCancel),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.privateAlbumFewDecoysContinue),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Whether to store the photos being hidden as HEIF. Asked, not assumed:
/// it rewrites the file the hidden album keeps. Dismissed is "keep".
Future<bool> _askHeif(BuildContext context, int count) async {
  final l10n = AppLocalizations.of(context)!;
  final convert = await showCupertinoDialog<bool>(
    context: context,
    builder: (context) => CupertinoAlertDialog(
      title: Text(l10n.hideHeifTitle),
      content: Text(l10n.hideHeifBody(count)),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.hideHeifKeep),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.hideHeifConvert),
        ),
      ],
    ),
  );
  return convert ?? false;
}

/// Hides [records]: tags each with a passcode hash — no separate album to
/// create first, the group sharing a hash *is* the album — and takes them
/// out of the OS photo library, which is the half that makes "hidden" mean
/// anything. Returns `false` (no-op) if the passcode popup was cancelled.
///
/// Never opens the album afterwards: somebody hiding a photo in front of
/// others wants it gone from the screen, not shown full-size.
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
  AiAnalysisStore? analysisStore,
  VoidCallback? onSettled,
}) async {
  final l10n = AppLocalizations.of(context)!;
  // No confirmation of our own, with one exception. The OS puts one up for
  // the delete a moment later — listing exactly what is about to go — and
  // two dialogs in a row asking the same question is how people learn to
  // tap through both.
  //
  // The exception is having nowhere to put the copy. Hiding removes the
  // photo from Photos, so with no bucket configured this app's container
  // becomes the only copy in existence, and iOS deletes that container
  // with the app. The OS prompt cannot say that, and it is not a detail:
  // it is the difference between hiding a photo and losing it.
  final buckets = targetsStore ?? BackupTargetsStore();
  if ((await _bucketCount(buckets)) == 0) {
    if (!context.mounted) return false;
    final proceed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.privateAlbumHideNoBucketTitle),
        content: Text(l10n.privateAlbumBackupNoBucket),
        actions: [
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.privateAlbumHideAnyway),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
        ],
      ),
    );
    if (proceed != true) return false;
  }
  var hash = passcodeHash;
  if (hash == null) {
    if (!context.mounted) return false;
    final passcode = await askHideCode(context);
    if (passcode == null) return false;
    hash = hashPasscode(passcode);
  }
  final keeper = custody ?? LibraryCustody(store: assetRecordStore);
  // Cloud-only or shrunk here: the full original is only in the bucket, and
  // hiding retracts the bucket copy. So it comes down first, after asking;
  // one that cannot be fetched is refused rather than lost.
  final cloudOnly = [
    for (final r in records)
      if (r.localDeleted || r.localOptimized) r,
  ];
  if (cloudOnly.isNotEmpty) {
    if (!context.mounted) return false;
    final proceed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(l10n.privateAlbumHideDownloadTitle),
        content: Text(l10n.privateAlbumHideDownloadBody(cloudOnly.length)),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.privateAlbumHideDownloadContinue),
          ),
        ],
      ),
    );
    if (proceed != true) return false;
  }
  // Asked now, not once the files are in hand, so nothing after this needs
  // the user. A photo whose file turns out to be HEIF already is kept as is.
  final heifCount = records
      .where(
        (r) => LibraryCustody.isHeifCandidate(
          r,
          // The bucket copy's extension says nothing about the file here:
          // with the optimized format it is `.heif` whatever this one is.
          r.sourcePath ?? '',
        ),
      )
      .length;
  var toHeif = false;
  if (heifCount > 0) {
    if (!context.mounted) return false;
    toHeif = await _askHeif(context, heifCount);
  }

  // Hidden at once, journaled; the copying out happens behind it. Until it
  // lands the original is still in Photos, so a failure only has to
  // un-hide.
  final transition = HiddenTransition(
    store: assetRecordStore,
    loadTargets: buckets.loadAll,
    pendingDeletes: pendingDeletes,
    analysisStore: analysisStore,
  );
  await transition.markHidden(records.map((r) => r.localId), hash);
  unawaited(
    _finishHiding(
      // Outlives the screen on purpose; only read again behind `mounted`.
      // ignore: use_build_context_synchronously
      context,
      l10n: l10n,
      records: records,
      cloudOnly: cloudOnly,
      store: assetRecordStore,
      keeper: keeper,
      buckets: buckets,
      transition: transition,
      toHeif: toHeif,
      onSettled: onSettled,
    ),
  );
  return true;
}

Future<void> _finishHiding(
  BuildContext context, {
  required AppLocalizations l10n,
  required List<AssetRecord> records,
  required List<AssetRecord> cloudOnly,
  required AssetRecordStore store,
  required LibraryCustody keeper,
  required BackupTargetsStore buckets,
  required HiddenTransition transition,
  required bool toHeif,
  VoidCallback? onSettled,
}) async {
  final refused = <AssetRecord>[];
  if (cloudOnly.isNotEmpty) {
    final restorer = OriginalRestore(targetsStore: buckets, recordStore: store);
    final fetched = <String, AssetRecord>{};
    for (final record in cloudOnly) {
      final fresh = await restorer.restore(record) == null
          ? null
          : await store.getByLocalId(record.localId);
      if (fresh == null) {
        refused.add(record);
      } else {
        fetched[record.localId] = fresh;
      }
    }
    records = [
      for (final r in records)
        if (!refused.contains(r)) fetched[r.localId] ?? r,
    ];
  }
  for (final record in refused) {
    await transition.cancelHide(record.localId);
  }
  final results = await keeper.takeOutMany(
    records,
    askHeif: (_) async => toHeif,
    restored: {for (final r in cloudOnly) r.localId},
  );

  var stillInLibrary = 0;
  var failed = refused.length;
  for (final record in records) {
    switch (results[record.localId] ?? CustodyResult.failed) {
      case CustodyResult.failed:
        // Nothing was copied out, so nothing should have been hidden
        // either — a hidden photo this app doesn't hold is a photo nobody
        // holds. And its bucket copy stays: it may be the only one.
        await transition.cancelHide(record.localId);
        failed++;
        continue;
      case CustodyResult.takenButStillInLibrary:
        stillInLibrary++;
      case CustodyResult.taken || CustodyResult.returned:
        break;
    }
    // Whatever is already in the bucket was uploaded in the clear. It
    // goes, but only once the carrier is in every bucket: until then it
    // is the only copy off this phone.
    await transition.settleHide(record.localId);
  }
  // Their encrypted copies go up now if the album's key is on hand,
  // otherwise when it is next opened.
  unawaited(PrivateAlbumScreen.hiddenBackup?.run());
  onSettled?.call();

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
}

/// Zero rather than throwing when the keychain can't be read: the warning
/// this gates is the safe answer, so an unreadable store shows it.
Future<int> _bucketCount(BackupTargetsStore store) async {
  try {
    return (await store.loadAll()).length;
  } catch (_) {
    return 0;
  }
}

/// Fires on touch-down, like the lock screen's keys. A tap button waits for
/// the finger to lift and loses the press when the next finger lands first
/// or the thumb slides — which is exactly how a code is typed fast.
class _KeypadKey extends StatefulWidget {
  const _KeypadKey({
    required this.size,
    required this.reach,
    required this.filled,
    required this.onPressed,
    required this.child,
  });

  final double size;
  final EdgeInsets reach;
  final bool filled;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  State<_KeypadKey> createState() => _KeypadKeyState();
}

class _KeypadKeyState extends State<_KeypadKey> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final face = widget.filled
        ? (_down ? const Color(0xFF636366) : const Color(0xFF3A3A3C))
        : (_down ? const Color(0x33FFFFFF) : const Color(0x00000000));
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: enabled
          ? (_) {
              _set(true);
              widget.onPressed!();
            }
          : null,
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: Padding(
        padding: widget.reach,
        child: Opacity(
          opacity: enabled ? 1 : 0.35,
          child: Container(
            width: widget.size,
            height: widget.size,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: face, shape: BoxShape.circle),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

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

/// The Utilities "Hidden" row's passcode popup: a 4-digit entry field plus
/// "Enter"/"Create New" buttons. No distinct "wrong passcode" state — any
/// 4 digits are valid input, resolved by the caller against
/// [PrivateAlbumStore].
Future<PrivateAlbumChoice?> showPrivateAlbumPasscodeSheet(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  final controller = TextEditingController();
  return showCupertinoDialog<PrivateAlbumChoice>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final valid = controller.text.length == 4;
        return CupertinoAlertDialog(
          title: Text(l10n.privateAlbumGateTitle),
          content: Column(
            children: [
              const SizedBox(height: 8),
              Text(l10n.privateAlbumGateBody),
              const SizedBox(height: 8),
              CupertinoTextField(
                controller: controller,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                textAlign: TextAlign.center,
                placeholder: l10n.privateAlbumGatePlaceholder,
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(onPressed: () => Navigator.of(context).pop(), child: Text(l10n.actionCancel)),
            CupertinoDialogAction(
              onPressed: valid
                  ? () => Navigator.of(context).pop(PrivateAlbumChoice(passcode: controller.text, createNew: false))
                  : null,
              child: Text(l10n.privateAlbumEnterButton),
            ),
            CupertinoDialogAction(
              onPressed: valid
                  ? () => Navigator.of(context).pop(PrivateAlbumChoice(passcode: controller.text, createNew: true))
                  : null,
              child: Text(l10n.privateAlbumCreateButton),
            ),
          ],
        );
      },
    ),
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

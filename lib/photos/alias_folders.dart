import '../settings/backup_targets_store.dart';
import '../storage/asset_record_store.dart';
import '../storage/passcode_hash.dart';
import '../vault/hidden_transition.dart';
import '../vault/keys.dart';
import '../vault/passcode_tags.dart';

/// A merged person's hidden folders, still under their old id's code. Once
/// the digits are typed on the kept person, each alias folder under them
/// moves into the kept one's: same digits, one folder.
class AliasFolders {
  AliasFolders({
    required this.store,
    required this.vaultKeys,
    BackupTargetsStore? targetsStore,
    HiddenTransition? transition,
  }) : _transition =
           transition ??
           HiddenTransition(
             store: store,
             loadTargets: (targetsStore ?? BackupTargetsStore()).loadAll,
           );

  final AssetRecordStore store;
  final VaultKeys vaultKeys;
  final HiddenTransition _transition;

  /// Folds each of [aliasIds]' folders under [digits] into [personId]'s.
  /// Returns the alias codes still holding photos that couldn't move
  /// (adopted by an older build, or whose full copy is only in a bucket),
  /// so they can still be opened.
  Future<List<String>> fold(
    String personId,
    List<String> aliasIds,
    String digits,
  ) async {
    if (aliasIds.isEmpty) return const [];
    final tags = PasscodeTags(records: store, vaultKeys: vaultKeys);
    final toCode = personAlbumCode(personId, digits);
    final toTag = await tags.tagFor(toCode);
    final left = <String>[];
    var moved = 0;
    for (final alias in aliasIds) {
      final code = personAlbumCode(alias, digits);
      final tag = await tags.tagFor(code);
      final records = await store.forPasscodeHash(tag);
      if (records.isEmpty) continue;
      final from = await vaultKeys.unlockAlbum(code, tag);
      final to = await vaultKeys.unlockAlbum(toCode, toTag);
      var stuck = false;
      for (final record in records) {
        final ok =
            (from == null || to != null) &&
            !isAdopted(record) &&
            await _transition.moveRecord(record, from: from, to: toTag);
        if (ok) {
          moved++;
        } else {
          stuck = true;
        }
      }
      if (stuck) left.add(code);
    }
    if (moved > 0) await vaultKeys.keepAlbum(toTag);
    return left;
  }
}

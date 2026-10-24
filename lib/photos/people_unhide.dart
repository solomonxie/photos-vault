import '../settings/backup_targets_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../storage/passcode_hash.dart';
import '../vault/hidden_transition.dart';
import '../vault/keys.dart';
import '../vault/passcode_tags.dart';
import 'library_custody.dart';
import 'person_store.dart';

class PeopleUnhideResult {
  const PeopleUnhideResult({
    this.returned = 0,
    this.failed = 0,
    this.skipped = 0,
  });

  final int returned;
  final int failed;

  /// Filed photos an older build adopted: they need their folder opened,
  /// where the bucket's index can be told.
  final int skipped;
}

/// Takes several people's photos out of their own hidden folders under one
/// code ([personAlbumCode]), and those of anyone merged into them. Each goes back on its person; one this app
/// imported (never in Photos) goes to Archive, as a people zip puts it, and
/// a camera-roll photo goes back to Photos as any un-hide does.
class PeopleUnhide {
  PeopleUnhide({
    required this.store,
    required this.personStore,
    VaultKeys? vaultKeys,
    LibraryCustody? custody,
    BackupTargetsStore? targetsStore,
  }) : _keys = vaultKeys ?? VaultKeys(),
       _custody = custody ?? LibraryCustody(store: store),
       _transition = HiddenTransition(
         store: store,
         loadTargets: (targetsStore ?? BackupTargetsStore()).loadAll,
       );

  final AssetRecordStore store;
  final PersonStore personStore;
  final VaultKeys _keys;
  final LibraryCustody _custody;
  final HiddenTransition _transition;

  Future<PeopleUnhideResult> run(List<String> personIds, String digits) async {
    final tags = PasscodeTags(
      records: store,
      people: personStore,
      vaultKeys: _keys,
    );
    var returned = 0, failed = 0, skipped = 0;
    for (final personId in personIds) {
      for (final id in [personId, ...await personStore.aliasesOf(personId)]) {
        final code = personAlbumCode(id, digits);
        final tag = await tags.tagFor(code);
        final records = await store.forPasscodeHash(tag);
        if (records.isEmpty) continue;
        final keys = await _keys.unlockAlbum(code, tag);
        final back = <String>[];
        final imported = <String>[];
        for (final record in records) {
          if (isAdopted(record)) {
            skipped++;
            continue;
          }
          if (!await _transition.unhideRecord(record, keys: keys)) {
            failed++;
            continue;
          }
          // Read again: un-hiding moved its file back out of `vault/plain/`.
          final fresh = await store.getByLocalId(record.localId) ?? record;
          if (await _custody.putBack(fresh) == CustodyResult.failed) {
            failed++;
            continue;
          }
          back.add(record.localId);
          if (record.sourceType != AssetSourceType.photoManager) {
            imported.add(record.localId);
          }
        }
        if (imported.isNotEmpty) await store.setArchived(imported, true);
        if (back.isNotEmpty) await personStore.addAssets(personId, back);
        returned += back.length;
      }
    }
    return PeopleUnhideResult(
      returned: returned,
      failed: failed,
      skipped: skipped,
    );
  }
}

import '../photos/person_store.dart';
import 'album_store.dart';
import 'asset_record_store.dart';

/// Snapshot imports in flight, process-wide. An import writes photo
/// records first and their album and people rows after, so a sweep that
/// read the records before the import and deleted after it would drop
/// memberships the import just made.
class RestoreGuard {
  static var _inFlight = 0;
  static var _generation = 0;

  static bool get busy => _inFlight > 0;
  static int get generation => _generation;

  static Future<T> run<T>(Future<T> Function() import) async {
    _inFlight++;
    _generation++;
    try {
      return await import();
    } finally {
      _inFlight--;
    }
  }
}

/// Album and people rows for photos that have no record at all — left by
/// permanent deletes made before those cleaned up after themselves. Once
/// per data root; returns how many photo ids were dropped (0 once done),
/// or null when it couldn't run yet (a restore under way, or no records).
///
/// Every id is checked against every record, deleted and hidden included:
/// only a photo the record store has never heard of is dropped.
Future<int?> sweepOrphanMemberships({
  required AssetRecordStore assetRecordStore,
  required AlbumStore albumStore,
  required PersonStore personStore,
}) async {
  if (await assetRecordStore.getAppState(_doneKey) != null) return 0;
  if (RestoreGuard.busy) return null;
  await Future.wait([
    albumStore.dropMembersOfMissingAlbums(),
    personStore.dropMembersOfMissingPeople(),
  ]);
  final generation = RestoreGuard.generation;

  final referenced = <String>{
    for (final ids in (await albumStore.allMemberships()).values) ...ids,
    for (final album in await albumStore.listAll())
      if (album.coverLocalId != null) album.coverLocalId!,
    for (final ids in (await personStore.allMemberships()).values) ...ids,
    for (final person in await personStore.listAll())
      if (person.avatarLocalId != null) person.avatarLocalId!,
  };
  // Records read last: anything an import adds before this is present.
  final records = await assetRecordStore.listAll();
  // An empty store is a wiped or not-yet-scanned library, not proof that
  // every photo is gone. Try again on a later launch.
  if (records.isEmpty) return null;
  // Single pass, once per data root, on a set of ids — bounded by the
  // library size and run a single time, not per reload.
  final known = {for (final r in records) r.localId};
  final orphans = referenced.difference(known);

  if (RestoreGuard.busy || RestoreGuard.generation != generation) return null;
  if (orphans.isNotEmpty) {
    // Both batches are queued before an import that starts now could reach
    // its own album or people writes, which come after its records.
    await Future.wait([
      albumStore.forgetAssets(orphans),
      personStore.forgetAssets(orphans),
    ]);
  }
  await assetRecordStore.setAppState(_doneKey, '1');
  return orphans.length;
}

const _doneKey = 'orphan_memberships_swept_v1';

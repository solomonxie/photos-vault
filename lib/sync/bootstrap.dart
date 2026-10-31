import 'package:sqflite/sqflite.dart';

import 'sync_store.dart';
import 'translate.dart';

/// This phone's whole shared library as ops, for its first sync: every
/// photo whose original is in the bucket, every album and named person, and
/// their memberships — never anything behind a passcode, never demo rows.
/// Entities in [skip] (the cloud already has them) are left out, their
/// memberships too: for those the cloud's values win and are applied here
/// instead, so a membership removed elsewhere doesn't come back.
///
/// Read a page at a time, queued a page at a time: the library is tens of
/// thousands of rows. Knowingly on the UI isolate (sqflite is async; the
/// work per row is one map), once per phone, behind a progress line.
Future<int> queueLibrary({
  required SyncStore store,
  required Database assets,
  required Database albums,
  required Database people,
  Set<String> skip = const {},
  void Function(int queued)? progress,
}) async {
  var queued = 0;
  final shared = <String>{};

  Future<void> page(
    Database db,
    String sql,
    List<Change> Function(Map<String, Object?> row) toChanges, {
    String key = 'k',
  }) async {
    Object? after = '';
    while (true) {
      final rows = await db.rawQuery(
        '$sql AND $key > ? ORDER BY $key LIMIT 1000',
        [after],
      );
      if (rows.isEmpty) return;
      final changes = [for (final r in rows) ...toChanges(r)];
      await store.addChanges(changes);
      queued += changes.length;
      progress?.call(queued);
      after = rows.last[key];
    }
  }

  String select(List<String> columns) => columns.join(', ');
  final now = DateTime.now().millisecondsSinceEpoch;

  await page(
    assets,
    'SELECT local_id AS k, ${select(assetCaptureColumns)} FROM asset_record '
    "WHERE original_status = 'uploaded' AND passcode_hash IS NULL",
    (r) {
      shared.add(r['k'] as String);
      if (skip.contains('asset/${r['k']}')) return const [];
      return translate(
        'asset_record',
        r['k'] as String,
        'insert',
        null,
        r,
        now,
      );
    },
  );
  await page(
    albums,
    'SELECT id AS k, ${select(albumCaptureColumns)} FROM album WHERE is_demo = 0',
    (r) => skip.contains('album/${r['k']}')
        ? const []
        : translate('album', r['k'] as String, 'insert', null, r, now),
  );
  await page(
    albums,
    "SELECT album_id || '/' || local_id AS k, album_id, local_id "
    'FROM album_asset WHERE 1',
    (r) =>
        shared.contains(r['local_id']) &&
            !skip.contains('album/${r['album_id']}')
        ? translate('album_asset', r['k'] as String, 'insert', null, r, now)
        : const [],
  );
  await page(
    people,
    'SELECT id AS k, ${select(personCaptureColumns)} FROM person '
    "WHERE is_demo = 0 AND COALESCE(passcode_hash, '') = ''",
    (r) => skip.contains('person/${r['k']}')
        ? const []
        : translate('person', r['k'] as String, 'insert', null, r, now),
  );
  await page(
    people,
    "SELECT pa.person_id || '/' || pa.local_id AS k, pa.person_id, pa.local_id "
    'FROM person_asset pa JOIN person p ON p.id = pa.person_id '
    "WHERE p.is_demo = 0 AND COALESCE(p.passcode_hash, '') = ''",
    (r) =>
        shared.contains(r['local_id']) &&
            !skip.contains('person/${r['person_id']}')
        ? translate('person_asset', r['k'] as String, 'insert', null, r, now)
        : const [],
  );
  return queued;
}

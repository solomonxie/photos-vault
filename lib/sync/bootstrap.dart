import 'package:sqflite/sqflite.dart';

import 'apply.dart';
import 'merge.dart';
import 'op.dart';

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
  queued += await queueProfiles(
    store: store,
    people: people,
    skip: {
      for (final k in skip)
        if (k.startsWith('person/')) k.substring(7),
    },
  );
  return queued;
}

/// This phone's presence ([presenceSet]) on the shared photos the cloud
/// already has, once per device id. Held and not listed: added. Listed and
/// no longer held: removed. Never listed, not held, and this phone's own
/// record (freed before presence synced): marked, so it reads as on no
/// phone. A record this phone only ever had from the cloud says nothing.
/// Photos the cloud lacks are left to their `add`, which carries presence.
/// Compared against the merged state: a rerun sends nothing new.
Future<int> queuePresence({
  required SyncStore store,
  required Database assets,
}) async {
  final device = await store.device();
  var queued = 0;
  Object? after = '';
  while (true) {
    final rows = await assets.rawQuery(
      'SELECT local_id AS k, local_deleted, platform FROM asset_record '
      "WHERE original_status = 'uploaded' AND passcode_hash IS NULL "
      'AND local_id > ? ORDER BY local_id LIMIT 1000',
      [after],
    );
    if (rows.isEmpty) break;
    after = rows.last['k'];
    final state = SyncState();
    await store.loadInto(state, [for (final r in rows) 'asset/${r['k']}']);
    final changes = <Change>[];
    for (final r in rows) {
      final id = r['k'] as String;
      final ent = state.entities['asset/$id'];
      if (ent == null || !ent.exists) continue;
      final held = r['local_deleted'] == 0;
      final listed = ent.members(presenceSet).contains(device);
      final known =
          ent.fields[presenceMarker] != null ||
          ent.sets.containsKey(presenceSet);
      if (held && !listed) {
        changes.addAll(presence(id, held: true));
      } else if (!held && listed) {
        changes.addAll(presence(id, held: false));
      } else if (!held && !known && r['platform'] != Applier.cloudPlatform) {
        changes.add(Change('asset', id, OpKind.set, f: presenceMarker, x: 1));
      }
    }
    await store.addChanges(changes);
    queued += changes.length;
  }
  return queued;
}

/// Person fields that arrived with profile sync: a phone that synced
/// before sends them once.
const _profileFields = [
  'avatar_face',
  'first_name',
  'middle_name',
  'last_name',
  'custom_fields',
];

/// Every open person's profile rows ([profileSets]) and details as ops.
/// People in [skip] are left to the cloud.
///
/// With [cloud] (a phone that synced before profiles did), what the cloud
/// already holds is kept: a field it has is not sent, a member it has is
/// not added again, so this phone's rows join the other phone's instead
/// of replacing them.
Future<int> queueProfiles({
  required SyncStore store,
  required Database people,
  Set<String> skip = const {},
  EntityState? Function(String personId)? cloud,
}) async {
  final everyone = await people.rawQuery(
    'SELECT id, ${_profileFields.join(', ')} FROM person '
    "WHERE is_demo = 0 AND COALESCE(passcode_hash, '') = ''",
  );
  final shared = {for (final r in everyone) r['id'] as String};
  final open = {
    for (final r in everyone)
      if (!skip.contains(r['id'])) r['id'] as String: r,
  };
  final changes = <Change>[];
  bool has(String id, String f) => cloud?.call(id)?.fields[f] != null;
  if (cloud != null) {
    for (final MapEntry(key: id, value: row) in open.entries) {
      if (cloud(id)?.exists != true) continue;
      for (final f in _profileFields) {
        if (!has(id, f) && row[f] != null && row[f] != '') {
          changes.add(Change('person', id, OpKind.set, f: f, x: row[f]));
        }
      }
      if (!has(id, profileMarker)) {
        changes.add(Change('person', id, OpKind.set, f: profileMarker, x: 1));
      }
    }
  }
  for (final r in await people.rawQuery(
    'SELECT person_id, payload FROM person_detail '
    "WHERE passcode_hash = '' AND sealed = 0",
  )) {
    final id = r['person_id'] as String;
    if (!open.containsKey(id) || has(id, 'details')) continue;
    changes.add(
      Change('person', id, OpKind.set, f: 'details', x: r['payload']),
    );
  }
  for (final MapEntry(key: table, value: (set, cols)) in profileSets.entries) {
    final columns = await people.rawQuery('PRAGMA table_info($table)');
    final sealed = columns.any((c) => c['name'] == 'passcode_hash');
    for (final r in await people.rawQuery(
      'SELECT person_id, ${cols.join(', ')} FROM $table'
      "${sealed ? " WHERE passcode_hash = ''" : ''}",
    )) {
      final id = r['person_id'] as String;
      if (!open.containsKey(id)) continue;
      if (table == 'person_relationship' &&
          !shared.contains(r['related_person_id'])) {
        continue;
      }
      final member = profileMember(table, r);
      if (cloud?.call(id)?.members(set).contains(member) ?? false) continue;
      changes.add(Change('person', id, OpKind.madd, f: set, x: member));
    }
  }
  for (var i = 0; i < changes.length; i += 1000) {
    await store.addChanges(
      changes.sublist(i, (i + 1000).clamp(0, changes.length)),
    );
  }
  return changes.length;
}

/// `travel.db` as ops: every place, entry and route, each route's stops,
/// and links — a photo link only to one [private] doesn't name, as at
/// collect.
/// Run on a phone's first sync, and once on a phone that joined before
/// travel was synced. Entities in [skip] keep the cloud's values.
Future<int> queueTravel({
  required SyncStore store,
  required Database travel,
  required Future<Set<String>> Function(Set<String> ids) private,
  Set<String> skip = const {},
}) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  final changes = <Change>[];
  Future<void> rows(
    String e,
    String table,
    List<String> columns,
    List<Change> Function(Map<String, Object?> row) toChanges,
  ) async {
    for (final r in await travel.rawQuery(
      'SELECT id AS k, ${columns.join(', ')} FROM $table',
    )) {
      if (!skip.contains('$e/${r['k']}')) changes.addAll(toChanges(r));
    }
  }

  await rows('place', 'place', [
    ...placeFields,
  ], (r) => translate('place', r['k'] as String, 'insert', null, r, now));
  await rows(
    'entry',
    'entry',
    entryCaptureColumns,
    (r) => translate('entry', r['k'] as String, 'insert', null, r, now),
  );
  await rows(
    'route',
    'route',
    [...routeFields, '${routeStopsSql('route.id')} AS stops'],
    (r) => [
      ...translate('route', r['k'] as String, 'insert', null, r, now),
      ...translate('stop', r['k'] as String, 'insert', null, r, now),
    ],
  );
  final links = await travel.rawQuery(
    "SELECT ${linkKeySql.replaceAll('{row}', 'link')} AS k, owner_kind, "
    'owner_id, target_kind, target_id FROM link',
  );
  final hidden = await private({
    for (final l in links)
      if (l['target_kind'] == 'asset') l['target_id'] as String,
  });
  for (final l in links) {
    if (skip.contains('${l['owner_kind']}/${l['owner_id']}')) continue;
    if (l['target_kind'] == 'asset' && hidden.contains(l['target_id'])) {
      continue;
    }
    changes.addAll(translate('link', l['k'] as String, 'insert', null, l, now));
  }
  for (var i = 0; i < changes.length; i += 1000) {
    await store.addChanges(
      changes.sublist(i, (i + 1000).clamp(0, changes.length)),
    );
  }
  return changes.length;
}

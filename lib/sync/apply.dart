import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'capture.dart';
import 'merge.dart';
import 'sync_store.dart';
import 'translate.dart';

/// What [Applier.apply] did, for the screens to reload.
class Applied {
  int assets = 0;

  /// Photo records made here for photos added elsewhere: the albums and
  /// people naming them are applied again so their memberships land.
  int created = 0;
  int albums = 0;
  int people = 0;
  int travel = 0;

  /// Keys left for the next round: a database had local edits not yet
  /// collected, and applying over them could have undone one.
  final deferred = <String>{};

  bool get any => assets + created + albums + people + travel > 0;
}

/// Pulled, merged state → this phone's own rows. Raw SQL inside
/// [applyingRemote], so none of it is captured and sent back.
///
/// Each database is written in one transaction that first checks its
/// `sync_outbox` is empty. A local write not yet collected isn't in the
/// merged state, and applying that state would quietly undo it; the
/// transaction holds the write lock, so none can arrive mid-way. With
/// something waiting, that database is skipped this round.
///
/// Photos: only records this phone already has, and never one behind a
/// passcode. Records for photos added elsewhere arrive with browser uploads
/// (IMPLEMENT_PLAN T6.x). People are never deleted from here: removing one
/// cascades through relationships and history the app owns.
class Applier {
  Applier({
    required this.store,
    required this.assets,
    required this.albums,
    required this.people,
    this.travel,
    this.homeTargetId,
  });

  /// The bucket a record made here says its objects are in.
  final String? homeTargetId;

  /// Records this applier made: photos added on another device, whose
  /// originals are only in the bucket.
  static const cloudPlatform = 'cloud';

  final SyncStore store;
  final Future<Database> Function() assets;
  final Future<Database> Function() albums;
  final Future<Database> Function() people;

  /// `travel.db`: places, entries and routes.
  final Future<Database> Function()? travel;

  static const _chunk = 500;

  Future<Applied> apply(Set<String> keys) async {
    final out = Applied();
    if (keys.isEmpty) return out;
    final state = SyncState();
    await store.loadInto(state, keys);
    List<EntityState> of(String e) => [
      for (final k in keys)
        if (k.startsWith('$e/'))
          if (state.entities[k] case final ent? when ent.exists) ent,
    ];
    final assetEnts = of('asset');
    final albumEnts = of('album');
    final personEnts = of('person');

    if (assetEnts.isNotEmpty) {
      final n = await _guarded(
        await assets(),
        (txn) => _assets(txn, assetEnts),
      );
      if (n == null) {
        out.deferred.addAll(assetEnts.map((e) => 'asset/${e.id}'));
      } else {
        out.assets = n.$1;
        out.created = n.$2;
      }
    }
    // Memberships only for photos this phone has, and not hidden ones.
    final memberIds = {
      for (final e in [...albumEnts, ...personEnts]) ...e.members('members'),
    };
    final present = await _presentPublic(await assets(), memberIds);
    if (albumEnts.isNotEmpty) {
      final n = await _guarded(
        await albums(),
        (txn) => _albums(txn, albumEnts, present),
      );
      if (n == null) {
        out.deferred.addAll(albumEnts.map((e) => 'album/${e.id}'));
      } else {
        out.albums = n;
      }
    }
    if (personEnts.isNotEmpty) {
      final n = await _guarded(
        await people(),
        (txn) => _people(txn, personEnts, present),
      );
      if (n == null) {
        out.deferred.addAll(personEnts.map((e) => 'person/${e.id}'));
      } else {
        out.people = n;
      }
    }
    final travelEnts = [...of('place'), ...of('entry'), ...of('route')];
    final travelDb = travel;
    if (travelEnts.isNotEmpty && travelDb != null) {
      final linked = await _presentPublic(await assets(), {
        for (final e in travelEnts) ...e.members('photos'),
      });
      final n = await _guarded(
        await travelDb(),
        (txn) => _travel(txn, travelEnts, linked),
      );
      if (n == null) {
        out.deferred.addAll(travelEnts.map((e) => '${e.e}/${e.id}'));
      } else {
        out.travel = n;
      }
    }
    return out;
  }

  /// Null when local edits are waiting in this database.
  static Future<T?> _guarded<T>(
    Database db,
    Future<T> Function(DatabaseExecutor txn) body,
  ) => applyingRemote(db, (txn) async {
    final waiting = Sqflite.firstIntValue(
      await txn.rawQuery('SELECT COUNT(*) FROM $syncOutboxTable'),
    );
    if ((waiting ?? 0) > 0) return null;
    return body(txn);
  });

  static Future<Set<String>> _presentPublic(
    Database db,
    Set<String> ids,
  ) async {
    final list = ids.toList();
    final out = <String>{};
    for (var i = 0; i < list.length; i += _chunk) {
      final part = list.sublist(i, (i + _chunk).clamp(0, list.length));
      final rows = await db.rawQuery(
        'SELECT local_id FROM asset_record WHERE passcode_hash IS NULL '
        'AND local_id IN (${List.filled(part.length, '?').join(',')})',
        part,
      );
      out.addAll(rows.map((r) => r['local_id'] as String));
    }
    return out;
  }

  static Object? _sql(Object? v) => v is bool ? (v ? 1 : 0) : v;

  /// One UPDATE that writes only when something differs, so an unchanged
  /// row doesn't move the change mark or the grid's revision.
  static Future<int> _update(
    DatabaseExecutor txn,
    String table,
    String where,
    List<Object?> whereArgs,
    Map<String, Object?> values,
  ) async {
    if (values.isEmpty) return 0;
    final cols = values.keys.toList();
    return txn.rawUpdate(
      'UPDATE $table SET ${cols.map((c) => '$c = ?').join(', ')} '
      'WHERE $where AND (${cols.map((c) => '$c IS NOT ?').join(' OR ')})',
      [...values.values.map(_sql), ...whereArgs, ...values.values.map(_sql)],
    );
  }

  static const _assetColumns = [
    'description',
    'location',
    'latitude',
    'longitude',
    'is_favorite',
    'is_archived',
    'created_at',
  ];

  Future<(int, int)> _assets(
    DatabaseExecutor txn,
    List<EntityState> ents,
  ) async {
    var changed = 0;
    var created = 0;
    final ids = [for (final e in ents) e.id];
    final local = <String, Map<String, Object?>>{};
    for (var i = 0; i < ids.length; i += _chunk) {
      final part = ids.sublist(i, (i + _chunk).clamp(0, ids.length));
      for (final r in await txn.rawQuery(
        'SELECT local_id, tags, deleted_at, binned_by, platform, passcode_hash '
        'FROM asset_record WHERE 1 '
        'AND local_id IN (${List.filled(part.length, '?').join(',')})',
        part,
      )) {
        local[r['local_id'] as String] = r;
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final ent in ents) {
      final row = local[ent.id];
      final f = ent.fields;
      final gone = f['hidden']?.x == true || f['purged']?.x != null;
      if (row == null) {
        if (!gone && await _create(txn, ent, now)) created++;
        continue;
      }
      if (row['passcode_hash'] != null) continue;
      if (gone) {
        // Only a record this applier made: this phone's own photos are never
        // another device's to remove.
        if (row['platform'] == cloudPlatform) {
          await txn.delete(
            'asset_record',
            where: 'local_id = ?',
            whereArgs: [ent.id],
          );
          await txn.delete(
            'derivative_target',
            where: 'local_id = ?',
            whereArgs: [ent.id],
          );
          changed++;
        }
        continue;
      }
      final values = <String, Object?>{
        for (final c in _assetColumns)
          if (f.containsKey(c)) c: c == 'description' ? f[c]!.x ?? '' : f[c]!.x,
      };
      final tags = _mergeTags(row['tags'] as String?, ent.members('tags'));
      if (tags != null) values['tags'] = tags;
      if (f.containsKey('deleted_at')) {
        final binned = f['deleted_at']!.x;
        if ((binned == null) != (row['deleted_at'] == null)) {
          values['deleted_at'] = binned;
          values['binned_by'] = binned == null ? null : binnedByCloud;
        }
      }
      if (values.isEmpty) continue;
      values['updated_at'] = now;
      final n = await _update(txn, 'asset_record', 'local_id = ?', [
        ent.id,
      ], values);
      if (n > 0) changed++;
    }
    return (changed, created);
  }

  /// A cloud-only record for a photo added on another device: its original
  /// and thumbnail are in the bucket, nothing is on this phone
  /// (`local_deleted`), so the upload engine leaves it alone and the grid
  /// draws it from the cloud thumbnail. False without an original key.
  Future<bool> _create(DatabaseExecutor txn, EntityState ent, int now) async {
    final f = ent.fields;
    Object? x(String k) => f[k]?.x;
    final original = x('original_key');
    if (original is! String || original.isEmpty) return false;
    final taken = x('created_at') is int ? x('created_at') as int : now;
    String? key(String k) =>
        x(k) is String && (x(k) as String).isNotEmpty ? x(k) as String : null;
    final keys = {
      'original': original,
      'thumbnail': key('thumbnail_key'),
      'medium': key('medium_key'),
      'live': key('live_key'),
      'edited': key('edited_key'),
    };
    await txn.insert('asset_record', {
      'local_id': ent.id,
      'content_hash': x('content_hash') ?? ent.id,
      'platform': cloudPlatform,
      'source_type': 'manualFile',
      'local_deleted': 1,
      'is_video': _sql(x('is_video') ?? 0),
      'is_live_photo': _sql(x('is_live_photo') ?? 0),
      'description': x('description') ?? '',
      'location': x('location'),
      'latitude': x('latitude'),
      'longitude': x('longitude'),
      'width': x('width'),
      'height': x('height'),
      'is_favorite': _sql(x('is_favorite') ?? 0),
      'is_archived': _sql(x('is_archived') ?? 0),
      'deleted_at': x('deleted_at'),
      'binned_by': x('deleted_at') == null ? null : binnedByCloud,
      'tags': jsonEncode(ent.members('tags')),
      'created_at': taken,
      'updated_at': now,
      'added_at': now,
      for (final MapEntry(:key, :value) in keys.entries)
        if (value != null) ...{
          '${key}_status': 'uploaded',
          '${key}_key': value,
          if (key == 'original') '${key}_hash': x('original_hash'),
        },
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    final target = homeTargetId;
    if (target != null) {
      for (final MapEntry(:key, :value) in keys.entries) {
        if (value == null) continue;
        await txn.insert('derivative_target', {
          'local_id': ent.id,
          'kind': key == 'live' ? 'livePhoto' : key,
          'target_id': target,
          'destination_key': value,
          'uploaded_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    return true;
  }

  /// Bin marker for a photo binned on another device.
  static const binnedByCloud = 'cloud';

  /// Local order kept; tags only the cloud has appended. Null when equal.
  static String? _mergeTags(String? raw, List<String> cloud) {
    List<String> local;
    try {
      local = [...(jsonDecode(raw ?? '[]') as List).whereType<String>()];
    } catch (_) {
      local = [];
    }
    final want = cloud.toSet();
    if (want.length == local.toSet().length && want.containsAll(local)) {
      return null;
    }
    return jsonEncode([
      for (final t in local)
        if (want.contains(t)) t,
      ...cloud.where((t) => !local.contains(t)),
    ]);
  }

  static Future<int> _members(
    DatabaseExecutor txn,
    String table,
    String ownerColumn,
    String owner,
    List<String> cloud,
    Set<String> present,
  ) async {
    final want = cloud.where(present.contains).toSet();
    final have = {
      for (final r in await txn.query(
        table,
        columns: ['local_id'],
        where: '$ownerColumn = ?',
        whereArgs: [owner],
      ))
        r['local_id'] as String,
    };
    final now = DateTime.now().millisecondsSinceEpoch;
    var n = 0;
    for (final id in want.difference(have)) {
      await txn.insert(table, {
        ownerColumn: owner,
        'local_id': id,
        'added_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      n++;
    }
    // Only photos the cloud could have listed: one this phone has but hasn't
    // shared yet is not the cloud's to take out.
    for (final id in have.difference(want).where(present.contains)) {
      await txn.delete(
        table,
        where: '$ownerColumn = ? AND local_id = ?',
        whereArgs: [owner, id],
      );
      n++;
    }
    return n;
  }

  Future<int> _albums(
    DatabaseExecutor txn,
    List<EntityState> ents,
    Set<String> present,
  ) async {
    var changed = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final ent in ents) {
      final f = ent.fields;
      if (f['deleted_at']?.x != null) {
        // Its notes stay: they don't sync, and the album may come back
        // under the same id.
        await txn.delete(
          'album_asset',
          where: 'album_id = ?',
          whereArgs: [ent.id],
        );
        changed += await txn.delete(
          'album',
          where: 'id = ?',
          whereArgs: [ent.id],
        );
        continue;
      }
      changed +=
          await txn.rawInsert(
                'INSERT OR IGNORE INTO album (id, name, created_at) VALUES (?, ?, ?)',
                [ent.id, f['name']?.x ?? '', now],
              ) >
              0
          ? 1
          : 0;
      final values = <String, Object?>{
        for (final c in const ['name', 'description', 'cover_local_id'])
          if (f.containsKey(c))
            c: f[c]!.x ?? (c == 'cover_local_id' ? null : ''),
      };
      final row = (await txn.query(
        'album',
        columns: ['tags'],
        where: 'id = ?',
        whereArgs: [ent.id],
      )).first;
      final tags = _mergeTags(row['tags'] as String?, ent.members('tags'));
      if (tags != null) values['tags'] = tags;
      changed += await _update(txn, 'album', 'id = ?', [ent.id], values);
      changed += await _members(
        txn,
        'album_asset',
        'album_id',
        ent.id,
        ent.members('members'),
        present,
      );
    }
    return changed;
  }

  Future<int> _people(
    DatabaseExecutor txn,
    List<EntityState> ents,
    Set<String> present,
  ) async {
    var changed = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final ent in ents) {
      final f = ent.fields;
      if (f['hidden']?.x == true) continue;
      final existing = await txn.query(
        'person',
        columns: ['passcode_hash'],
        where: 'id = ?',
        whereArgs: [ent.id],
      );
      if (existing.isNotEmpty &&
          ((existing.first['passcode_hash'] as String?) ?? '').isNotEmpty) {
        continue;
      }
      if (existing.isEmpty) {
        if (f['deleted_at']?.x != null) continue;
        await txn.insert('person', {
          'id': ent.id,
          'name': f['name']?.x ?? '',
          'created_at': now,
          'updated_at': now,
        });
        changed++;
      }
      final values = <String, Object?>{
        for (final c in personFields)
          if (f.containsKey(c))
            c:
                f[c]!.x ??
                (_blankText.contains(c)
                    ? ''
                    : c == 'custom_fields'
                    ? '[]'
                    : null),
      };
      if (values.isNotEmpty) {
        values['updated_at'] = now;
        changed += await _update(txn, 'person', 'id = ?', [ent.id], values);
      }
      changed += await _members(
        txn,
        'person_asset',
        'person_id',
        ent.id,
        ent.members('members'),
        present,
      );
    }
    // After every person is in: a relationship names another one.
    for (final ent in ents) {
      if (ent.fields[profileMarker]?.x != 1) continue;
      final open = await txn.query(
        'person',
        columns: ['id'],
        where: "id = ? AND COALESCE(passcode_hash, '') = ''",
        whereArgs: [ent.id],
      );
      if (open.isEmpty) continue;
      changed += await _profile(txn, ent, now);
    }
    return changed;
  }

  static const _blankText = {
    'name',
    'bio',
    'first_name',
    'middle_name',
    'last_name',
  };

  /// What identifies one profile row of a person, per table.
  static const _profileKeys = {
    'person_event': ['id'],
    'person_location': ['id'],
    'person_known_as': ['person_id', 'kind', 'key'],
    'person_alias': ['alias_id'],
    'person_group': ['person_id', 'group_id', 'passcode_hash'],
    'person_relationship': ['person_id', 'related_person_id', 'passcode_hash'],
  };

  /// A person's open details and profile rows made what the cloud holds.
  /// Rows behind a passcode are never read or touched.
  static Future<int> _profile(
    DatabaseExecutor txn,
    EntityState ent,
    int now,
  ) async {
    var n = 0;
    final f = ent.fields;
    if (f.containsKey('details')) {
      final payload = f['details']!.x;
      if (payload is String) {
        final had = await txn.query(
          'person_detail',
          columns: ['payload'],
          where: "person_id = ? AND passcode_hash = ''",
          whereArgs: [ent.id],
        );
        if (had.isEmpty || had.first['payload'] != payload) {
          await txn.insert('person_detail', {
            'person_id': ent.id,
            'passcode_hash': '',
            'payload': payload,
            'sealed': 0,
            'updated_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          n++;
        }
      } else {
        n += await txn.delete(
          'person_detail',
          where: "person_id = ? AND passcode_hash = '' AND sealed = 0",
          whereArgs: [ent.id],
        );
      }
    }
    for (final MapEntry(key: table, value: (set, cols))
        in profileSets.entries) {
      final keys = _profileKeys[table]!;
      final info = await txn.rawQuery('PRAGMA table_info($table)');
      final sealed = info.any((c) => c['name'] == 'passcode_hash');
      final local = {
        for (final r in await txn.query(
          table,
          where: "person_id = ?${sealed ? " AND passcode_hash = ''" : ''}",
          whereArgs: [ent.id],
        ))
          profileMember(table, r): r,
      };
      final want = ent.members(set).toSet();
      for (final MapEntry(key: m, value: row) in local.entries) {
        if (want.contains(m)) continue;
        n += await txn.delete(
          table,
          where: keys.map((k) => '$k = ?').join(' AND '),
          whereArgs: [for (final k in keys) row[k]],
        );
      }
      for (final m in want.difference(local.keys.toSet())) {
        final Map<String, Object?> values;
        if (cols.length == 1) {
          values = {cols.single: m};
        } else {
          try {
            values = (jsonDecode(m) as Map).cast<String, Object?>();
          } catch (_) {
            continue;
          }
        }
        if (table == 'person_relationship') {
          final other = await txn.query(
            'person',
            columns: ['id'],
            where: 'id = ?',
            whereArgs: [values['related_person_id']],
          );
          if (other.isEmpty) continue;
        }
        await txn.insert(table, {
          'person_id': ent.id,
          for (final c in cols) c: values[c],
          if (sealed) 'passcode_hash': '',
          if (sealed) 'payload': '',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        n++;
      }
    }
    return n;
  }

  /// Places first (entries and stops name them), then entries, then routes.
  /// A place deleted elsewhere stays while something here still uses it.
  Future<int> _travel(
    DatabaseExecutor txn,
    List<EntityState> ents,
    Set<String> present,
  ) async {
    var changed = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    Object? x(EntityState ent, String f, Object? fallback) =>
        ent.fields[f]?.x ?? fallback;
    bool gone(EntityState ent) => ent.fields['deleted_at']?.x != null;
    Map<String, Object?> values(EntityState ent, Map<String, Object?> blank) =>
        {
          for (final MapEntry(:key, :value) in blank.entries)
            if (ent.fields.containsKey(key)) key: x(ent, key, value),
        };

    for (final ent in ents.where((e) => e.e == 'place')) {
      if (gone(ent)) {
        final used = await txn.rawQuery(
          'SELECT EXISTS (SELECT 1 FROM entry WHERE place_id = ?1) '
          'OR EXISTS (SELECT 1 FROM stop WHERE place_id = ?1) '
          'OR EXISTS (SELECT 1 FROM place WHERE parent_id = ?1) AS used',
          [ent.id],
        );
        if (used.first['used'] != 1) {
          changed += await txn.delete(
            'place',
            where: 'id = ?',
            whereArgs: [ent.id],
          );
        }
        continue;
      }
      final blank = <String, Object?>{
        'name': '',
        'kind': 'point',
        'lat': 0.0,
        'lng': 0.0,
        'parent_id': null,
        'country': '',
        'address': '',
        'category': '',
        'description': '',
        'created_at': now,
      };
      changed += await _upsert(txn, 'place', ent.id, blank, values(ent, blank));
    }

    for (final ent in ents.where((e) => e.e == 'entry')) {
      if (gone(ent)) {
        changed += await txn.delete(
          'entry',
          where: 'id = ?',
          whereArgs: [ent.id],
        );
        changed += await txn.delete(
          'link',
          where: "owner_kind = 'entry' AND owner_id = ?",
          whereArgs: [ent.id],
        );
        continue;
      }
      final blank = <String, Object?>{
        'place_id': '',
        'kind': 'impression',
        'at': null,
        'title': '',
        'text': '',
        'rating': null,
        'created_at': now,
      };
      final v = values(ent, blank);
      final local = await txn.query(
        'entry',
        columns: ['tags'],
        where: 'id = ?',
        whereArgs: [ent.id],
      );
      final tags = _mergeTags(
        local.isEmpty ? '[]' : local.first['tags'] as String?,
        ent.members('tags'),
      );
      if (tags != null) v['tags'] = tags;
      v['updated_at'] = now;
      changed += await _upsert(txn, 'entry', ent.id, {
        ...blank,
        'tags': '[]',
        'updated_at': now,
      }, v);
      changed += await _links(txn, ent, present);
    }

    for (final ent in ents.where((e) => e.e == 'route')) {
      if (gone(ent)) {
        changed += await txn.delete(
          'route',
          where: 'id = ?',
          whereArgs: [ent.id],
        );
        for (final t in const ['stop', 'leg']) {
          await txn.delete(t, where: 'route_id = ?', whereArgs: [ent.id]);
        }
        await txn.delete(
          'link',
          where: "owner_kind = 'route' AND owner_id = ?",
          whereArgs: [ent.id],
        );
        continue;
      }
      final blank = <String, Object?>{
        'title': '',
        'note': '',
        'starts': null,
        'ends': null,
        'created_at': now,
      };
      changed += await _upsert(txn, 'route', ent.id, blank, values(ent, blank));
      if (ent.fields['stops']?.x case final String stops) {
        changed += await _stops(txn, ent.id, stops);
      }
      changed += await _links(txn, ent, present);
    }
    if (changed > 0) {
      await txn.rawUpdate('UPDATE rev SET n = n + 1 WHERE id = 1');
    }
    return changed;
  }

  /// Inserted with [blank] when missing, then [values] written over it.
  static Future<int> _upsert(
    DatabaseExecutor txn,
    String table,
    String id,
    Map<String, Object?> blank,
    Map<String, Object?> values,
  ) async {
    final inserted = await txn.insert(table, {
      'id': id,
      ...blank,
      ...values,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    if (inserted > 0) return 1;
    return _update(txn, table, 'id = ?', [id], values);
  }

  /// A route's stops and legs, rewritten only when the list differs.
  static Future<int> _stops(
    DatabaseExecutor txn,
    String routeId,
    String json,
  ) async {
    final List<Map<String, Object?>> want;
    try {
      want = [
        for (final s in jsonDecode(json) as List)
          (s as Map).cast<String, Object?>(),
      ];
    } catch (_) {
      return 0;
    }
    final now = await txn.rawQuery('SELECT ${routeStopsSql('?')} AS stops', [
      routeId,
    ]);
    final have = now.first['stops'];
    if (have is String && _sameJson(have, want)) return 0;
    await txn.delete('stop', where: 'route_id = ?', whereArgs: [routeId]);
    await txn.delete('leg', where: 'route_id = ?', whereArgs: [routeId]);
    for (final (i, s) in want.indexed) {
      final place = s['place'];
      if (place is! String) continue;
      await txn.insert('stop', {
        'route_id': routeId,
        'position': i,
        'place_id': place,
        'arrived': s['arrived'],
        'note': s['note'] ?? '',
      });
      if (i + 1 < want.length && s['mode'] is String) {
        await txn.insert('leg', {
          'route_id': routeId,
          'position': i,
          'mode': s['mode'],
          'note': s['leg'] ?? '',
          'from_place': place,
          'to_place': want[i + 1]['place'] ?? '',
          'needs_review': s['review'] ?? 0,
        });
      }
    }
    return 1;
  }

  static bool _sameJson(String raw, List<Map<String, Object?>> want) {
    try {
      return jsonEncode(jsonDecode(raw)) == jsonEncode(want);
    } catch (_) {
      return false;
    }
  }

  /// An entry's or route's photos and people. A photo link is removed only
  /// for one the cloud could have listed ([present]), as album members.
  static Future<int> _links(
    DatabaseExecutor txn,
    EntityState ent,
    Set<String> present,
  ) async {
    var n = 0;
    for (final MapEntry(key: target, value: set) in linkSets.entries) {
      final cloud = ent.members(set).toSet();
      final want = target == 'asset' ? cloud.intersection(present) : cloud;
      final have = {
        for (final r in await txn.query(
          'link',
          columns: ['target_id'],
          where: 'owner_kind = ? AND owner_id = ? AND target_kind = ?',
          whereArgs: [ent.e, ent.id, target],
        ))
          r['target_id'] as String,
      };
      for (final id in want.difference(have)) {
        await txn.insert('link', {
          'owner_kind': ent.e,
          'owner_id': ent.id,
          'target_kind': target,
          'target_id': id,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        n++;
      }
      for (final id in have.difference(want)) {
        if (target == 'asset' && !present.contains(id)) continue;
        n += await txn.delete(
          'link',
          where: 'owner_kind = ? AND owner_id = ? AND target_kind = ? AND target_id = ?',
          whereArgs: [ent.e, ent.id, target, id],
        );
      }
    }
    return n;
  }
}

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'capture.dart';
import 'merge.dart';
import 'sync_store.dart';

/// What [Applier.apply] did, for the screens to reload.
class Applied {
  int assets = 0;
  int albums = 0;
  int people = 0;

  /// Keys left for the next round: a database had local edits not yet
  /// collected, and applying over them could have undone one.
  final deferred = <String>{};

  bool get any => assets + albums + people > 0;
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
  });

  final SyncStore store;
  final Future<Database> Function() assets;
  final Future<Database> Function() albums;
  final Future<Database> Function() people;

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
        out.assets = n;
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
    return out;
  }

  /// Null when local edits are waiting in this database.
  static Future<int?> _guarded(
    Database db,
    Future<int> Function(DatabaseExecutor txn) body,
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

  Future<int> _assets(DatabaseExecutor txn, List<EntityState> ents) async {
    var changed = 0;
    final ids = [for (final e in ents) e.id];
    final local = <String, Map<String, Object?>>{};
    for (var i = 0; i < ids.length; i += _chunk) {
      final part = ids.sublist(i, (i + _chunk).clamp(0, ids.length));
      for (final r in await txn.rawQuery(
        'SELECT local_id, tags, deleted_at, binned_by FROM asset_record '
        'WHERE passcode_hash IS NULL '
        'AND local_id IN (${List.filled(part.length, '?').join(',')})',
        part,
      )) {
        local[r['local_id'] as String] = r;
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final ent in ents) {
      final row = local[ent.id];
      if (row == null) continue;
      final f = ent.fields;
      if (f['hidden']?.x == true || f['purged']?.x != null) continue;
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
    return changed;
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
        for (final c in const [
          'name',
          'bio',
          'birth_date',
          'gender',
          'avatar_local_id',
        ])
          if (f.containsKey(c))
            c: f[c]!.x ?? (c == 'name' || c == 'bio' ? '' : null),
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
    return changed;
  }
}

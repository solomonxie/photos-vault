import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show Database, DatabaseFactory, OpenDatabaseOptions;

import '../backup/database_copy.dart';
import 'ai_analysis.dart';
import 'person.dart' show FaceRect;

/// Which of [found] each of [old] now is: the same box, or failing that the
/// one it overlaps most (at least half). Each found box is taken once, in
/// [old]'s order; an old box with no match is left out.
Map<FaceRect, FaceRect> carryFaces(List<FaceRect> old, List<FaceRect> found) {
  const least = 0.5;
  final free = found.toSet();
  final out = <FaceRect, FaceRect>{};
  for (final f in old) {
    if (free.remove(f)) out[f] = f;
  }
  for (final f in old) {
    if (out.containsKey(f)) continue;
    FaceRect? best;
    var bestScore = least;
    for (final candidate in free) {
      final score = f.overlap(candidate);
      if (score >= bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    if (best == null) continue;
    free.remove(best);
    out[f] = best;
  }
  return out;
}

/// One face put to one person.
typedef FaceLink = ({String localId, FaceRect face, String personId});

/// One unnamed face put in an imported group.
typedef GroupedFace = ({String localId, FaceRect face, String groupId});

/// What [AiAnalysisStore.importNamedFaces] wrote.
typedef FaceImportWrite = ({
  List<FaceLink> linked,
  Set<String> undescribed,
  int grouped,
});

/// An imported group of unnamed faces, waiting for a name.
class StoredFaceGroup {
  const StoredFaceGroup({required this.id, required this.faces, this.suggest});

  final String id;

  /// A name the file proposed. Nothing is named until somebody taps.
  final String? suggest;
  final List<({String localId, FaceRect face})> faces;
}

/// Local `sqflite` store of what the on-device pass found per photo (faces,
/// their descriptors and guesses), keyed by `AssetRecord.localId`. The
/// `tags`/`description`/`reviewed` columns are left over from the removed
/// AI suggestions and no longer read or written.
class AiAnalysisStore {
  AiAnalysisStore({DatabaseFactory? databaseFactory, String? path})
    : this._(databaseFactory, path);

  AiAnalysisStore._(this._databaseFactory, this._path);

  /// Resolved on first use rather than in the constructor: the global
  /// factory throws where there's no `sqflite` (a widget test), and merely
  /// *having* an analysis store is not the same as asking it anything.
  final DatabaseFactory? _databaseFactory;

  DatabaseFactory get _factory => _databaseFactory ?? sqflite.databaseFactory;
  final String? _path;

  Database? _db;

  static const _table = 'ai_analysis';

  /// One row per described face; `person_id` set on the confirmed ones,
  /// which are the reference set a suggestion is matched against.
  static const _descriptorTable = 'face_descriptor';

  /// One row per face the matcher has looked at, named or not.
  static const _suggestionTable = 'face_suggestion';

  /// Imported groups of unnamed faces ([StoredFaceGroup]), and which face
  /// is in which. A deleted group stays as `dismissed`, and a face taken
  /// out as `removed`, so the same file imported again changes nothing.
  static const _groupTable = 'face_group';
  static const _memberTable = 'face_group_member';

  /// Bumped after every write to faces, descriptors or guesses, by any
  /// instance: they share one file. What a cached face pass keys on.
  static int _writes = 0;

  int get revision => _writes;

  ({int at, Map<String, int> counts})? _faceCounts;

  Future<Database>? _opening;

  /// Single-flight: concurrent first callers share one open.
  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final opening = _opening ??= _openOnce();
    try {
      return await opening;
    } finally {
      _opening = null;
    }
  }

  Future<Database> _openOnce() async {
    final path =
        _path ?? p.join(await _factory.getDatabasesPath(), 'ai_analysis.db');
    final db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 8,
        onCreate: (db, version) => db.execute('''
          CREATE TABLE $_table (
            local_id TEXT PRIMARY KEY,
            people_count INTEGER NOT NULL,
            analyzed_at INTEGER NOT NULL,
            tags TEXT NOT NULL DEFAULT '',
            description TEXT NOT NULL DEFAULT '',
            reviewed INTEGER NOT NULL DEFAULT 0,
            faces TEXT NOT NULL DEFAULT '',
            upright INTEGER NOT NULL DEFAULT 1
          )
        '''),
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onOpen: _createDescriptors,
        // v2 added the columns a suggestion waits in. Added rather than
        // rebuilt: the face counts already in here cost a pass over the
        // whole library to work out again.
        // v3 added `faces`: where in the photo each detected face is, so a
        // face can be *shown* without re-running Vision over the library.
        // The count alone could say "three faces here" and never draw one.
        onUpgrade: (db, from, to) async {
          if (from < 2) {
            await db.execute(
              "ALTER TABLE $_table ADD COLUMN tags TEXT NOT NULL DEFAULT ''",
            );
            await db.execute(
              'ALTER TABLE $_table '
              "ADD COLUMN description TEXT NOT NULL DEFAULT ''",
            );
            await db.execute(
              'ALTER TABLE $_table '
              'ADD COLUMN reviewed INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (from < 3) {
            await db.execute(
              "ALTER TABLE $_table ADD COLUMN faces TEXT NOT NULL DEFAULT ''",
            );
          }
          if (from < 4) await _createDescriptors(db);
          // v5 let an unnamed face keep a descriptor too, so "who else
          // looks like this?" is a query rather than thousands of Vision
          // calls. SQLite can't relax NOT NULL in place.
          if (from < 5) {
            await db.execute('DROP TABLE IF EXISTS $_descriptorTable');
            await _createDescriptors(db);
          }
          // v6 dropped `event_label`, the occasion guess behind a collection
          // that albums already did better. Rebuilt rather than
          // `DROP COLUMN`, which needs a newer SQLite than every phone has.
          if (from < 6) await _dropEventLabel(db);
          // v7: boxes found before this were measured on the raw sensor
          // buffer, not the upright picture (05#7). Marked, and moved by
          // the analyze pass once the photo's orientation is read.
          if (from < 7) {
            await db.execute(
              'ALTER TABLE $_table '
              'ADD COLUMN upright INTEGER NOT NULL DEFAULT 0',
            );
            await db.execute("UPDATE $_table SET upright = 1 WHERE faces = ''");
          }
          // v8: indexes for the per-person reads (DB-10).
          if (from < 8) await _createDescriptors(db);
        },
      ),
    );
    _db = db;
    // The file may have been restored or replaced while closed.
    _writes++;
    return db;
  }

  static Future<void> _dropEventLabel(Database db) async {
    await db.execute('ALTER TABLE $_table RENAME TO ${_table}_old');
    await db.execute('''
      CREATE TABLE $_table (
        local_id TEXT PRIMARY KEY,
        people_count INTEGER NOT NULL,
        analyzed_at INTEGER NOT NULL,
        tags TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT '',
        reviewed INTEGER NOT NULL DEFAULT 0,
        faces TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute(
      'INSERT INTO $_table (local_id, people_count, analyzed_at, tags, '
      'description, reviewed, faces) SELECT local_id, people_count, '
      'analyzed_at, tags, description, reviewed, faces FROM ${_table}_old',
    );
    await db.execute('DROP TABLE ${_table}_old');
  }

  /// Idempotent, and run on open as well as on upgrade: the descriptors are
  /// derivable — every row can be rebuilt from the photo and the person it's
  /// linked to — so a missing table is worth healing rather than migrating
  /// carefully around.
  static Future<void> _createDescriptors(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_descriptorTable (
        local_id TEXT NOT NULL,
        face TEXT NOT NULL,
        person_id TEXT,
        revision INTEGER NOT NULL,
        vector BLOB NOT NULL,
        confirmed_at INTEGER NOT NULL,
        PRIMARY KEY (local_id, face)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_suggestionTable (
        local_id TEXT NOT NULL,
        face TEXT NOT NULL,
        person_id TEXT,
        PRIMARY KEY (local_id, face)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS face_descriptor_person '
      'ON $_descriptorTable (person_id, confirmed_at) '
      'WHERE person_id IS NOT NULL',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS face_suggestion_person '
      'ON $_suggestionTable (person_id) WHERE person_id IS NOT NULL',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_groupTable (
        id TEXT PRIMARY KEY,
        suggest TEXT,
        created_at INTEGER NOT NULL,
        dismissed INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_memberTable (
        local_id TEXT NOT NULL,
        face TEXT NOT NULL,
        group_id TEXT NOT NULL,
        removed INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (local_id, face)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS face_group_member_group '
      'ON $_memberTable (group_id)',
    );
  }

  /// Names [faces] as [personId]: the row is the link, the vector column
  /// is left empty now nothing on the phone compares faces.
  Future<void> nameFaces(
    Iterable<({String localId, FaceRect face})> faces,
    String personId,
  ) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final f in faces) {
      batch.rawInsert(
        'INSERT INTO $_descriptorTable '
        '(local_id, face, person_id, revision, vector, confirmed_at) '
        'VALUES (?, ?, ?, 0, ?, ?) '
        'ON CONFLICT (local_id, face) DO UPDATE SET '
        'person_id = excluded.person_id, confirmed_at = excluded.confirmed_at',
        [f.localId, f.face.encode(), personId, Uint8List(0), now],
      );
    }
    await batch.commit(noResult: true);
    _writes++;
  }

  /// The faces in [localId] already named, by their box: Find Faces doesn't
  /// ask about them again.
  Future<Map<FaceRect, String>> namedFacesIn(String localId) async {
    final db = await _open();
    final rows = await db.query(
      _descriptorTable,
      columns: const ['face', 'person_id'],
      where: 'local_id = ? AND person_id IS NOT NULL',
      whereArgs: [localId],
    );
    return {
      for (final row in rows)
        FaceRect.decode(row['face'] as String?) ?? _wholeFrame:
            row['person_id'] as String,
    };
  }

  /// [namedFacesIn] for many photos, keyed by local id.
  Future<Map<String, Map<FaceRect, String>>> namedFacesOf(
    Iterable<String> localIds,
  ) async {
    final out = <String, Map<FaceRect, String>>{};
    await _eachRead(
      localIds,
      (where) =>
          'SELECT local_id, face, person_id FROM $_descriptorTable '
          'WHERE person_id IS NOT NULL AND $where',
      (row) {
        final face = FaceRect.decode(row['face'] as String?);
        if (face == null) return;
        (out[row['local_id'] as String] ??= {})[face] =
            row['person_id'] as String;
      },
    );
    return out;
  }

  /// The found boxes of these photos, and whether they are still on the
  /// raw sensor buffer (05#7). Photos never looked at, or owed another
  /// look, have none.
  Future<Map<String, ({List<FaceRect> faces, bool legacy})>> faceRowsOf(
    Iterable<String> localIds,
  ) async {
    final out = <String, ({List<FaceRect> faces, bool legacy})>{};
    await _eachRead(
      localIds,
      (where) =>
          'SELECT local_id, people_count, faces, upright FROM $_table '
          'WHERE $where',
      (row) {
        final pending = (row['people_count'] as num) < 0;
        out[row['local_id'] as String] = (
          faces: pending
              ? const <FaceRect>[]
              : decodeFaces(row['faces'] as String?),
          legacy: !pending && row['upright'] == 0,
        );
      },
    );
    return out;
  }

  /// Names faces, and puts unnamed ones in groups, from an imported face
  /// file — or names a group's faces — in one transaction. [added] boxes
  /// join each photo's found faces first; a photo never looked at takes
  /// them as its faces. A face already named keeps its name and is never
  /// put in a group, and a photo whose boxes are still on the sensor
  /// buffer is left alone. A face named here leaves its group.
  ///
  /// A face with no descriptor gets an empty one, named and dated 0, so it
  /// sorts behind every described reference and takes no place in the
  /// cap from one: the analyze pass describes it the next time the photo
  /// is looked at, keeping the name and dating it then.
  /// [clearAll]: every guess goes, the reference set changed wholesale;
  /// otherwise only these photos' guesses.
  Future<FaceImportWrite> importNamedFaces(
    List<FaceLink> links, {
    Map<String, List<FaceRect>> added = const {},
    List<GroupedFace> grouped = const [],
    Map<String, String?> groups = const {},
    bool clearAll = true,
  }) async {
    if (links.isEmpty && grouped.isEmpty) {
      return (linked: <FaceLink>[], undescribed: <String>{}, grouped: 0);
    }
    final ids = {
      for (final l in links) l.localId,
      for (final g in grouped) g.localId,
    }.toList();
    final db = await _open();
    final result = await db.transaction((txn) async {
      final rows = <String, Map<String, Object?>>{};
      final described = <String, String?>{};
      for (var i = 0; i < ids.length; i += 900) {
        final chunk = ids.skip(i).take(900).toList();
        final where =
            'local_id IN (${List.filled(chunk.length, '?').join(',')})';
        for (final row in await txn.rawQuery(
          'SELECT local_id, people_count, faces, upright FROM $_table '
          'WHERE $where',
          chunk,
        )) {
          rows[row['local_id'] as String] = row;
        }
        for (final row in await txn.rawQuery(
          'SELECT local_id, face, person_id FROM $_descriptorTable '
          'WHERE $where',
          chunk,
        )) {
          described['${row['local_id']}|${row['face']}'] =
              row['person_id'] as String?;
        }
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final batch = txn.batch();
      final legacy = {
        for (final MapEntry(:key, :value) in rows.entries)
          if (value['upright'] == 0 && (value['people_count'] as num) >= 0) key,
      };
      added.forEach((localId, boxes) {
        if (legacy.contains(localId)) return;
        final row = rows[localId];
        final pending = row == null || (row['people_count'] as num) < 0;
        final faces = [if (!pending) ...decodeFaces(row['faces'] as String?)];
        for (final box in boxes) {
          if (!faces.contains(box)) faces.add(box);
        }
        batch.insert(_table, {
          'local_id': localId,
          'people_count': faces.length,
          'analyzed_at': now,
          'faces': encodeFaces(faces),
          'upright': 1,
        }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
        batch.update(
          _table,
          {
            'people_count': faces.length,
            'faces': encodeFaces(faces),
            'upright': 1,
            if (pending) 'analyzed_at': now,
          },
          where: 'local_id = ?',
          whereArgs: [localId],
        );
      });
      final linked = <FaceLink>[];
      final undescribed = <String>{};
      for (final l in links) {
        if (legacy.contains(l.localId)) continue;
        final key = faceKey(l.localId, l.face);
        if (described.containsKey(key)) {
          if (described[key] != null) continue;
          batch.update(
            _descriptorTable,
            {'person_id': l.personId, 'confirmed_at': now},
            where: 'local_id = ? AND face = ? AND person_id IS NULL',
            whereArgs: [l.localId, l.face.encode()],
          );
        } else {
          batch.insert(_descriptorTable, {
            'local_id': l.localId,
            'face': l.face.encode(),
            'person_id': l.personId,
            'revision': 0,
            'vector': Uint8List(0),
            'confirmed_at': 0,
          }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
          undescribed.add(l.localId);
        }
        batch.delete(
          _memberTable,
          where: 'local_id = ? AND face = ?',
          whereArgs: [l.localId, l.face.encode()],
        );
        described[key] = l.personId;
        linked.add(l);
      }
      for (final id in {for (final g in grouped) g.groupId}) {
        batch.insert(_groupTable, {
          'id': id,
          'suggest': groups[id],
          'created_at': now,
        }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
      }
      var groupedCount = 0;
      for (final g in grouped) {
        if (legacy.contains(g.localId)) continue;
        if (described[faceKey(g.localId, g.face)] != null) continue;
        // The same file again changes nothing. A newer run moves a face
        // only out of a deleted group, or one it was taken out of.
        batch.rawInsert(
          'INSERT INTO $_memberTable (local_id, face, group_id, removed) '
          'VALUES (?, ?, ?, 0) '
          'ON CONFLICT (local_id, face) DO UPDATE SET '
          'group_id = excluded.group_id, removed = 0 '
          'WHERE excluded.group_id <> $_memberTable.group_id '
          'AND ($_memberTable.removed = 1 OR $_memberTable.group_id IN '
          '(SELECT id FROM $_groupTable WHERE dismissed = 1)) '
          'AND excluded.group_id NOT IN '
          '(SELECT id FROM $_groupTable WHERE dismissed = 1)',
          [g.localId, g.face.encode(), g.groupId],
        );
        groupedCount++;
      }
      if (clearAll) {
        batch.delete(_suggestionTable);
      } else {
        final named = {for (final l in linked) l.localId}.toList();
        for (var i = 0; i < named.length; i += 900) {
          final chunk = named.skip(i).take(900).toList();
          batch.delete(
            _suggestionTable,
            where: 'local_id IN (${List.filled(chunk.length, '?').join(',')})',
            whereArgs: chunk,
          );
        }
      }
      await batch.commit(noResult: true);
      return (linked: linked, undescribed: undescribed, grouped: groupedCount);
    });
    _writes++;
    return result;
  }

  /// Every live group with unnamed faces still in it. Hidden photos'
  /// faces are already gone ([forgetFacesOf]); the caller still filters
  /// by what may be shown.
  Future<List<StoredFaceGroup>> faceGroups() async {
    final db = await _open();
    final groups = await db.query(_groupTable, where: 'dismissed = 0');
    final rows = await db.rawQuery(
      'SELECT m.group_id, m.local_id, m.face FROM $_memberTable m '
      'JOIN $_groupTable g ON g.id = m.group_id '
      'WHERE g.dismissed = 0 AND m.removed = 0 AND NOT EXISTS ('
      'SELECT 1 FROM $_descriptorTable d WHERE d.local_id = m.local_id '
      'AND d.face = m.face AND d.person_id IS NOT NULL)',
    );
    final faces = <String, List<({String localId, FaceRect face})>>{};
    for (final row in rows) {
      final face = FaceRect.decode(row['face'] as String?);
      if (face == null) continue;
      (faces[row['group_id'] as String] ??= []).add((
        localId: row['local_id'] as String,
        face: face,
      ));
    }
    return [
      for (final g in groups)
        if (faces[g['id']] case final mine?)
          StoredFaceGroup(
            id: g['id'] as String,
            suggest: g['suggest'] as String?,
            faces: mine,
          ),
    ];
  }

  /// Faces waiting in a live group, encoded, by photo: they're named
  /// there, not asked about again in Faces to Name. Cached until the next
  /// write.
  Future<Map<String, Set<String>>> groupedFaces() async {
    final at = _writes;
    final held = _grouped;
    if (held != null && held.at == at) return held.faces;
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT m.local_id, m.face FROM $_memberTable m '
      'JOIN $_groupTable g ON g.id = m.group_id '
      'WHERE g.dismissed = 0 AND m.removed = 0',
    );
    final faces = <String, Set<String>>{};
    for (final row in rows) {
      (faces[row['local_id'] as String] ??= {}).add(row['face'] as String);
    }
    _grouped = (at: at, faces: faces);
    return faces;
  }

  ({int at, Map<String, Set<String>> faces})? _grouped;

  /// Undoes naming [faces] [personId]'s from group [groupId]: the names
  /// come off and the faces go back in the group. The photos where
  /// [personId] has no named face left.
  Future<Set<String>> returnToGroup(
    String personId,
    String groupId,
    List<({String localId, FaceRect face})> faces,
  ) async {
    final db = await _open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final f in faces) {
        batch.update(
          _descriptorTable,
          {'person_id': null},
          where: 'local_id = ? AND face = ? AND person_id = ?',
          whereArgs: [f.localId, f.face.encode(), personId],
        );
        batch.rawInsert(
          'INSERT INTO $_memberTable (local_id, face, group_id, removed) '
          'VALUES (?, ?, ?, 0) ON CONFLICT (local_id, face) DO UPDATE SET '
          'group_id = excluded.group_id, removed = 0',
          [f.localId, f.face.encode(), groupId],
        );
      }
      await batch.commit(noResult: true);
    });
    _writes++;
    final ids = {for (final f in faces) f.localId};
    final named = await namedFacesOf(ids);
    return {
      for (final id in ids)
        if (!(named[id]?.containsValue(personId) ?? false)) id,
    };
  }

  /// Takes faces out of their group: "not this group". They stay unnamed,
  /// and the same file imported again doesn't put them back.
  Future<void> ungroupFaces(
    Iterable<({String localId, FaceRect face})> faces,
  ) async {
    final db = await _open();
    final batch = db.batch();
    for (final f in faces) {
      batch.update(
        _memberTable,
        {'removed': 1},
        where: 'local_id = ? AND face = ?',
        whereArgs: [f.localId, f.face.encode()],
      );
    }
    await batch.commit(noResult: true);
    _writes++;
  }

  /// Deletes a group. Kept as a marker, so importing the same file again
  /// doesn't bring it back.
  Future<void> dismissGroup(String id) async {
    final db = await _open();
    await db.update(
      _groupTable,
      {'dismissed': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
    _writes++;
  }

  /// Moves this photo's group memberships onto the boxes [map] picks; a
  /// face nobody's box lands on leaves its group.
  static Future<void> _carryGroups(
    sqflite.DatabaseExecutor txn,
    String localId,
    Map<FaceRect, FaceRect> Function(List<FaceRect> old) map,
  ) async {
    final rows = await txn.query(
      _memberTable,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
    if (rows.isEmpty) return;
    final old = [
      for (final row in rows) FaceRect.decode(row['face'] as String?),
    ];
    final moved = map([...old.nonNulls]);
    if (old.every((f) => f != null && moved[f] == f)) return;
    await txn.delete(_memberTable, where: 'local_id = ?', whereArgs: [localId]);
    for (var i = 0; i < rows.length; i++) {
      final to = old[i] == null ? null : moved[old[i]];
      if (to == null) continue;
      await txn.insert(_memberTable, {
        ...rows[i],
        'face': to.encode(),
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
    }
  }

  /// [facesByAsset] for these photos only.
  Future<Map<String, List<FaceRect>>> facesOf(Iterable<String> localIds) async {
    final out = <String, List<FaceRect>>{};
    await _eachRead(
      localIds,
      (where) =>
          'SELECT local_id, faces FROM $_table '
          "WHERE faces <> '' AND $where",
      (row) {
        final faces = decodeFaces(row['faces'] as String?);
        if (faces.isNotEmpty) out[row['local_id'] as String] = faces;
      },
    );
    return out;
  }

  /// How many boxes each photo with faces has, counted in SQL so no box
  /// is decoded. Cached until the next write.
  Future<Map<String, int>> faceCounts() async {
    final at = _writes;
    final held = _faceCounts;
    if (held != null && held.at == at) return held.counts;
    final db = await _open();
    final rows = await db.rawQuery(
      "SELECT local_id, length(faces) - length(replace(faces, ';', '')) + 1 "
      "AS n FROM $_table WHERE faces <> ''",
    );
    final counts = {
      for (final row in rows)
        row['local_id'] as String: (row['n'] as num).toInt(),
    };
    _faceCounts = (at: at, counts: counts);
    return counts;
  }

  Future<void> _eachRead(
    Iterable<String> localIds,
    String Function(String where) sql,
    void Function(Map<String, Object?> row) onRow,
  ) async {
    final all = localIds.toSet().toList();
    if (all.isEmpty) return;
    final db = await _open();
    for (var i = 0; i < all.length; i += 900) {
      final ids = all.skip(i).take(900).toList();
      final rows = await db.rawQuery(
        sql('local_id IN (${List.filled(ids.length, '?').join(',')})'),
        ids,
      );
      rows.forEach(onRow);
    }
  }

  static String faceKey(String localId, FaceRect face) =>
      '$localId|${face.encode()}';

  /// Which face in this photo is this person's, if one has been
  /// confirmed. Null when nobody has said — a group shot where they were
  /// linked to the photo rather than to a face in it.
  Future<FaceRect?> faceOfPersonIn(String localId, String personId) async {
    final db = await _open();
    final rows = await db.query(
      _descriptorTable,
      columns: const ['face'],
      where: 'local_id = ? AND person_id = ?',
      whereArgs: [localId, personId],
      orderBy: 'confirmed_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return FaceRect.decode(rows.single['face'] as String?);
  }

  /// Faces confirmed as [personId]'s, newest confirmation first, one per
  /// photo — what a profile photo is picked from.
  Future<List<({String localId, FaceRect face})>> facesOfPerson(
    String personId, {
    int limit = 60,
  }) async {
    final db = await _open();
    final rows = await db.query(
      _descriptorTable,
      columns: const ['local_id', 'face'],
      where: 'person_id = ?',
      whereArgs: [personId],
      orderBy: 'confirmed_at DESC',
    );
    final seen = <String>{};
    final out = <({String localId, FaceRect face})>[];
    for (final row in rows) {
      final id = row['local_id'] as String;
      final face = FaceRect.decode(row['face'] as String?);
      if (face == null || !seen.add(id)) continue;
      out.add((localId: id, face: face));
      if (out.length == limit) break;
    }
    return out;
  }

  static const _wholeFrame = FaceRect(0, 0, 1, 1);

  /// Marks every photo as never-looked-at, so the whole library is walked
  /// again from the newest.
  ///
  Future<void> forgetFaces() async {
    final db = await _open();
    await db.update(_table, {'people_count': _neverLooked, 'faces': ''});
    await db.delete(_suggestionTable);
    _writes++;
  }

  /// A face count no scan produces — the marker that says "look at this
  /// again", written without dropping the row.
  static const _neverLooked = -1;

  /// Drops every face, vector and guess of these photos — for hiding. The
  /// paid analysis stays; the face pass looks again if one comes back.
  Future<void> forgetFacesOf(Iterable<String> localIds) =>
      _eachChunk(localIds, (batch, where, ids) {
        batch
          ..delete(_descriptorTable, where: where, whereArgs: ids)
          ..delete(_suggestionTable, where: where, whereArgs: ids)
          ..delete(_memberTable, where: where, whereArgs: ids)
          ..update(
            _table,
            {'people_count': _neverLooked, 'faces': ''},
            where: where,
            whereArgs: ids,
          );
      });

  /// Drops everything kept about these photos — for a permanent delete.
  Future<void> forgetAssets(Iterable<String> localIds) =>
      _eachChunk(localIds, (batch, where, ids) {
        batch
          ..delete(_descriptorTable, where: where, whereArgs: ids)
          ..delete(_suggestionTable, where: where, whereArgs: ids)
          ..delete(_memberTable, where: where, whereArgs: ids)
          ..delete(_table, where: where, whereArgs: ids);
      });

  Future<void> _eachChunk(
    Iterable<String> localIds,
    void Function(sqflite.Batch batch, String where, List<String> ids) add,
  ) async {
    final all = localIds.toSet().toList();
    if (all.isEmpty) return;
    final db = await _open();
    final batch = db.batch();
    for (var i = 0; i < all.length; i += 900) {
      final ids = all.skip(i).take(900).toList();
      add(
        batch,
        'local_id IN (${List.filled(ids.length, '?').join(',')})',
        ids,
      );
    }
    await batch.commit(noResult: true);
    _writes++;
  }

  /// Forgets one confirmed face — what undoing a name has to mean. Without
  /// it an accepted-then-undone guess leaves the wrong face in the
  /// reference set, where it goes on pulling later photos towards the
  /// person the user just said it wasn't.
  Future<void> forgetDescriptor(String localId, FaceRect face) async {
    final db = await _open();
    await db.update(
      _descriptorTable,
      {'person_id': null},
      where: 'local_id = ? AND face = ?',
      whereArgs: [localId, face.encode()],
    );
    _writes++;
  }

  /// Forgets the faces confirmed as [personId] on one photo — what taking
  /// the photo off the person has to mean.
  /// [from]'s faces in [localIds] become [to]'s: photos moved from one
  /// person to another take what they look like with them.
  Future<void> movePersonOn(
    String from,
    String to,
    Iterable<String> localIds,
  ) async {
    final db = await _open();
    final ids = localIds.toList();
    final batch = db.batch();
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      batch.update(
        _descriptorTable,
        {'person_id': to},
        where:
            'person_id = ? AND local_id IN '
            '(${List.filled(chunk.length, '?').join(',')})',
        whereArgs: [from, ...chunk],
      );
    }
    await batch.commit(noResult: true);
    _writes++;
  }

  Future<void> forgetPersonOn(
    String personId,
    Iterable<String> localIds,
  ) async {
    final db = await _open();
    final ids = localIds.toList();
    final batch = db.batch();
    // Under SQLite's bound-parameter limit.
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      batch.update(
        _descriptorTable,
        {'person_id': null},
        where:
            'person_id = ? AND local_id IN '
            '(${List.filled(chunk.length, '?').join(',')})',
        whereArgs: [personId, ...chunk],
      );
    }
    await batch.commit(noResult: true);
    _writes++;
  }

  /// Every face named [from] becomes [to]'s: two people merged into one.
  Future<void> movePerson(String from, String to) async {
    final db = await _open();
    for (final table in [_descriptorTable, _suggestionTable]) {
      await db.update(
        table,
        {'person_id': to},
        where: 'person_id = ?',
        whereArgs: [from],
      );
    }
    _writes++;
  }

  /// Forgets a person's faces — what deleting them has to mean, or they go
  /// on being suggested by name after the name is gone. The descriptors
  /// themselves stay, unnamed: describing a face costs a Vision pass, and
  /// the description was never wrong, only the name on it.
  Future<void> forgetPerson(String personId) async {
    final db = await _open();
    await db.update(
      _descriptorTable,
      {'person_id': null},
      where: 'person_id = ?',
      whereArgs: [personId],
    );
    await db.delete(
      _suggestionTable,
      where: 'person_id = ?',
      whereArgs: [personId],
    );
    _writes++;
  }

  /// A compact copy at [dest] without anything of [hiddenIds].
  ///
  /// In the backup because faces take hours of the phone's time to work
  /// out again and are small.
  Future<bool> copyTo(String dest, Set<String> hiddenIds) async => copyDatabase(
    await _open(),
    _factory,
    dest,
    dropIds: hiddenIds,
    scrub: [
      for (final table in [
        _table,
        _descriptorTable,
        _suggestionTable,
        _memberTable,
      ])
        'DELETE FROM $table WHERE local_id IN (SELECT id FROM drop_ids)',
    ],
  );

  /// Rows of a backed-up copy at [path] added to this store; a face here
  /// already keeps what it has. See [mergeDatabase].
  Future<int> mergeFrom(String path) async =>
      mergeDatabase(await _open(), path);

  /// Moves whenever a face, label, group or suggestion is written. The
  /// change log doesn't cover this database; the backup gate needs this.
  Future<int> dataMark() async => tablesMark(await _open(), [
    _table,
    _descriptorTable,
    _suggestionTable,
    _groupTable,
    _memberTable,
  ]);

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _writes++;
  }

  Future<void> clearAll() async {
    final db = await _open();
    final batch = db.batch()
      ..delete(_suggestionTable)
      ..delete(_descriptorTable)
      ..delete(_memberTable)
      ..delete(_groupTable)
      ..delete(_table);
    await batch.commit(noResult: true);
    _writes++;
  }

  Future<void> save(AiPhotoAnalysis analysis) async {
    final db = await _open();
    await db.insert(_table, {
      'local_id': analysis.localId,
      'people_count': analysis.peopleCount,
      'analyzed_at': analysis.analyzedAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
    _writes++;
  }

  /// Records what the on-device pass found and nothing else.
  Future<void> saveFaceCount({
    required String localId,
    required int peopleCount,
    required DateTime analyzedAt,
    List<FaceRect> faces = const [],
  }) async {
    final db = await _open();
    final encoded = encodeFaces(faces);
    await db.transaction((txn) async {
      final updated = await txn.update(
        _table,
        {
          'people_count': peopleCount,
          'analyzed_at': analyzedAt.millisecondsSinceEpoch,
          'faces': encoded,
          'upright': 1,
        },
        where: 'local_id = ?',
        whereArgs: [localId],
      );
      if (updated == 0) {
        await txn.insert(_table, {
          'local_id': localId,
          'people_count': peopleCount,
          'analyzed_at': analyzedAt.millisecondsSinceEpoch,
          'faces': encoded,
          'upright': 1,
        }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
      }
      await _carryDescriptors(txn, localId, (old) => carryFaces(old, faces));
      await _carryGroups(txn, localId, (old) => carryFaces(old, faces));
    });
    _writes++;
  }

  /// Moves this photo's descriptors onto the boxes [map] picks for their
  /// old ones. A named face nobody's box lands on keeps its old key; an
  /// unnamed one goes, or "who else" lists the same face twice (05#23).
  /// Its guesses go too: they are about boxes that moved.
  static Future<void> _carryDescriptors(
    sqflite.DatabaseExecutor txn,
    String localId,
    Map<FaceRect, FaceRect> Function(List<FaceRect> old) map,
  ) async {
    final rows = await txn.query(
      _descriptorTable,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
    if (rows.isEmpty) return;
    final old = [
      for (final row in rows) FaceRect.decode(row['face'] as String?),
    ];
    // Named first, so a name wins the box.
    final order = List.generate(rows.length, (i) => i)
      ..sort(
        (a, b) => (rows[a]['person_id'] == null ? 1 : 0).compareTo(
          rows[b]['person_id'] == null ? 1 : 0,
        ),
      );
    final moved = map([for (final i in order) ?old[i]]);
    final unchanged = [
      for (var i = 0; i < rows.length; i++)
        if (old[i] != null && moved[old[i]] == old[i]) i,
    ];
    if (unchanged.length == rows.length) return;
    await txn.delete(
      _descriptorTable,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
    for (final i in order) {
      final from = old[i];
      final to = from == null ? null : moved[from];
      final named = rows[i]['person_id'] != null;
      if (to == null && !named) continue;
      await txn.insert(_descriptorTable, {
        ...rows[i],
        if (to != null) 'face': to.encode(),
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
    }
    await txn.delete(
      _suggestionTable,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Moves a photo's boxes from the raw sensor buffer they were measured
  /// on to the upright picture, for the EXIF [orientation] (05#7).
  /// Descriptors and guesses follow, so names stay on their faces.
  Future<void> reorientFaces(String localId, int orientation) async {
    final db = await _open();
    await db.transaction((txn) async {
      final rows = await txn.query(
        _table,
        columns: const ['faces', 'upright'],
        where: 'local_id = ?',
        whereArgs: [localId],
        limit: 1,
      );
      if (rows.isEmpty || rows.single['upright'] == 1) return;
      final faces = decodeFaces(rows.single['faces'] as String?);
      await txn.update(
        _table,
        {
          'faces': encodeFaces([
            for (final f in faces) f.oriented(orientation),
          ]),
          'upright': 1,
        },
        where: 'local_id = ?',
        whereArgs: [localId],
      );
      if (orientation <= 1 || orientation > 8) return;
      await _carryDescriptors(
        txn,
        localId,
        (old) => {for (final f in old) f: f.oriented(orientation)},
      );
      await _carryGroups(
        txn,
        localId,
        (old) => {for (final f in old) f: f.oriented(orientation)},
      );
    });
    _writes++;
  }

  /// Where the faces are, per photo — for drawing one, which a count can't.
  /// Photos analyzed before v3 have none stored and simply aren't in here.
  Future<Map<String, List<FaceRect>>> facesByAsset() async {
    final db = await _open();
    final rows = await db.query(
      _table,
      columns: const ['local_id', 'faces'],
      where: "faces <> ''",
    );
    return {
      for (final row in rows)
        if (decodeFaces(row['faces'] as String?) case final faces
            when faces.isNotEmpty)
          row['local_id'] as String: faces,
    };
  }

  /// The faces already found in one photo. Empty for a photo the analyze
  /// pass hasn't reached yet, and for one scanned before the boxes were
  /// stored at all — in both cases there is nothing to show but the button
  /// that looks again.
  Future<List<FaceRect>> facesFor(String localId) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      columns: const ['faces'],
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (rows.isEmpty) return const [];
    return decodeFaces(rows.first['faces'] as String?);
  }

  /// `x,y,w,h;x,y,w,h` — one column, and readable in a database browser,
  /// same trade as [FaceRect.encode] itself.
  static String encodeFaces(List<FaceRect> faces) =>
      faces.map((f) => f.encode()).join(';');

  static List<FaceRect> decodeFaces(String? value) {
    if (value == null || value.isEmpty) return const [];
    return [for (final part in value.split(';')) ?FaceRect.decode(part)];
  }

  /// One photo's row, or `null` if it has never been looked at.
  Future<AiPhotoAnalysis?> get(String localId) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<Map<String, AiPhotoAnalysis>> listAll() async {
    final db = await _open();
    final rows = await db.query(_table);
    return {for (final row in rows) row['local_id'] as String: _fromRow(row)};
  }

  static AiPhotoAnalysis _fromRow(Map<String, Object?> row) => AiPhotoAnalysis(
    localId: row['local_id'] as String,
    peopleCount: row['people_count'] as int,
    analyzedAt: DateTime.fromMillisecondsSinceEpoch(row['analyzed_at'] as int),
    legacyBoxes: row['upright'] == 0,
  );
}

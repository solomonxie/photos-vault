import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show Database, DatabaseFactory, OpenDatabaseOptions;

import '../backup/database_copy.dart';
import 'ai_analysis.dart';
import 'face_matcher.dart' show ConfirmedFace, DescribedFace;
import 'on_device_vision.dart' show FaceDescriptor;
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

/// Local `sqflite` store of what the on-device pass found per photo (faces,
/// their descriptors and guesses), keyed by `AssetRecord.localId`, plus the
/// legacy vendor tags and captions.
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

  /// Bumped after every write to faces, descriptors or guesses, by any
  /// instance: they share one file. What a cached face pass keys on.
  static int _writes = 0;

  int get revision => _writes;

  ({int at, Map<String, int> counts})? _faceCounts;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
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
  }

  /// What the matcher guessed, per face. A row with a null `person_id` is
  /// "looked, no opinion" — which has to be recorded, or the analyze pass
  /// asks the same unanswerable question of the same photo forever.
  Future<void> saveSuggestions(
    String localId,
    Map<String, String?> byFace,
  ) async {
    final db = await _open();
    final batch = db.batch();
    byFace.forEach((face, personId) {
      batch.insert(_suggestionTable, {
        'local_id': localId,
        'face': face,
        'person_id': personId,
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
    });
    await batch.commit(noResult: true);
    _writes++;
  }

  /// Every guess worth showing, keyed `localId` → encoded face → person.
  /// Rows with no opinion are left out — the caller wants names, and their
  /// absence is already the answer.
  Future<Map<String, Map<String, String>>> suggestionsByAsset() async {
    final db = await _open();
    final rows = await db.query(
      _suggestionTable,
      where: 'person_id IS NOT NULL',
    );
    final byAsset = <String, Map<String, String>>{};
    for (final row in rows) {
      byAsset.putIfAbsent(
        row['local_id'] as String,
        () => {},
      )[row['face'] as String] = row['person_id'] as String;
    }
    return byAsset;
  }

  /// The guesses for one photo, encoded face → person. Faces the matcher
  /// had no opinion about are left out.
  Future<Map<String, String>> suggestionsFor(String localId) async {
    final db = await _open();
    final rows = await db.query(
      _suggestionTable,
      where: 'local_id = ? AND person_id IS NOT NULL',
      whereArgs: [localId],
    );
    return {
      for (final row in rows) row['face'] as String: row['person_id'] as String,
    };
  }

  /// Photos the matcher has already been over — what stops the pass
  /// repeating itself.
  Future<Set<String>> matchedAssets() async {
    final db = await _open();
    final rows = await db.query(
      _suggestionTable,
      columns: const ['local_id'],
      distinct: true,
    );
    return {for (final row in rows) row['local_id'] as String};
  }

  /// Drops the guesses for a photo — after one of its faces is named, they
  /// are about a question that's been answered.
  Future<void> clearSuggestions(String localId) async {
    final db = await _open();
    await db.delete(
      _suggestionTable,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
    _writes++;
  }

  /// Everything the matcher decided, so a newly-named person gets a fresh
  /// hearing on the faces it previously had no opinion about.
  Future<void> clearAllSuggestions() async {
    final db = await _open();
    await db.delete(_suggestionTable);
    _writes++;
  }

  /// What a face looks like, whether or not anybody has said whose it is.
  ///
  /// [personId] null is the ordinary case: a face the analyze pass has
  /// described and nobody has named. Those are what "who else looks like
  /// this?" searches, and keeping them is the difference between a query
  /// and a thousand Vision calls per tap.
  Future<void> saveDescriptor({
    required String localId,
    required FaceRect face,
    required FaceDescriptor descriptor,
    String? personId,
  }) async {
    if (descriptor.isEmpty) return;
    final db = await _open();
    // A re-description (no [personId]) replaces the vector and keeps the
    // name and its date: 05#4.
    await db.rawInsert(
      'INSERT INTO $_descriptorTable '
      '(local_id, face, person_id, revision, vector, confirmed_at) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT (local_id, face) DO UPDATE SET '
      'revision = excluded.revision, vector = excluded.vector, '
      'person_id = COALESCE(excluded.person_id, person_id), '
      'confirmed_at = CASE WHEN excluded.person_id IS NULL '
      'THEN confirmed_at ELSE excluded.confirmed_at END',
      [
        localId,
        face.encode(),
        personId,
        descriptor.revision,
        descriptor.encode(),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    _writes++;
  }

  /// [attachDescriptor] for many faces, in one transaction.
  Future<void> attachDescriptors(
    Iterable<({String localId, FaceRect face})> faces,
    String personId,
  ) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final f in faces) {
      batch.update(
        _descriptorTable,
        {'person_id': personId, 'confirmed_at': now},
        where: 'local_id = ? AND face = ?',
        whereArgs: [f.localId, f.face.encode()],
      );
    }
    await batch.commit(noResult: true);
    _writes++;
  }

  /// Every stored descriptor of these photos, keyed by [faceKey].
  Future<Map<String, FaceDescriptor>> descriptorsOf(
    Iterable<String> localIds,
  ) async {
    final all = localIds.toSet().toList();
    final db = await _open();
    final out = <String, FaceDescriptor>{};
    for (var i = 0; i < all.length; i += 900) {
      final ids = all.skip(i).take(900).toList();
      final rows = await db.query(
        _descriptorTable,
        columns: const ['local_id', 'face', 'revision', 'vector'],
        where: 'local_id IN (${List.filled(ids.length, '?').join(',')})',
        whereArgs: ids,
      );
      for (final row in rows) {
        out['${row['local_id']}|${row['face']}'] = FaceDescriptor.decode(
          row['vector'] as Uint8List?,
          (row['revision'] as num?)?.toInt() ?? 0,
        );
      }
    }
    return out;
  }

  /// [descriptorsOf], unnamed faces only.
  Future<Map<String, FaceDescriptor>> unnamedDescriptorsOf(
    Iterable<String> localIds,
  ) async {
    final out = <String, FaceDescriptor>{};
    await _eachRead(
      localIds,
      (where) =>
          'SELECT local_id, face, revision, vector FROM $_descriptorTable '
          'WHERE person_id IS NULL AND $where',
      // Re-encoded, so the key matches a box decoded from `faces`.
      (row) =>
          out[faceKey(
            row['local_id'] as String,
            FaceRect.decode(row['face'] as String?) ?? _wholeFrame,
          )] = FaceDescriptor.decode(
            row['vector'] as Uint8List?,
            (row['revision'] as num?)?.toInt() ?? 0,
          ),
    );
    return out;
  }

  /// [suggestionsByAsset] for these photos only.
  Future<Map<String, Map<String, String>>> suggestionsOf(
    Iterable<String> localIds,
  ) async {
    final byAsset = <String, Map<String, String>>{};
    await _eachRead(
      localIds,
      (where) =>
          'SELECT local_id, face, person_id FROM $_suggestionTable '
          'WHERE person_id IS NOT NULL AND $where',
      (row) => byAsset.putIfAbsent(
        row['local_id'] as String,
        () => {},
      )[row['face'] as String] = row['person_id'] as String,
    );
    return byAsset;
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

  /// [clearSuggestions] for many photos.
  Future<void> clearSuggestionsOf(Iterable<String> localIds) =>
      _eachChunk(localIds, (batch, where, ids) {
        batch.delete(_suggestionTable, where: where, whereArgs: ids);
      });

  /// Puts a name to a face already described — what naming does, without
  /// asking Vision about a photo it has already been over.
  Future<void> attachDescriptor(
    String localId,
    FaceRect face,
    String personId,
  ) async {
    final db = await _open();
    await db.update(
      _descriptorTable,
      {
        'person_id': personId,
        'confirmed_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'local_id = ? AND face = ?',
      whereArgs: [localId, face.encode()],
    );
    _writes++;
  }

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

  /// The descriptor for one face, or an empty one where there isn't one.
  Future<FaceDescriptor?> descriptorFor(String localId, FaceRect face) async {
    final db = await _open();
    final rows = await db.query(
      _descriptorTable,
      where: 'local_id = ? AND face = ?',
      whereArgs: [localId, face.encode()],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return FaceDescriptor.decode(
      rows.first['vector'] as Uint8List?,
      (rows.first['revision'] as num?)?.toInt() ?? 0,
    );
  }

  /// Every described face, named or not — what grouping searches.
  Future<List<DescribedFace>> allDescribedFaces() async {
    final db = await _open();
    final rows = await db.query(_descriptorTable);
    return [
      for (final row in rows)
        DescribedFace(
          localId: row['local_id'] as String,
          face: FaceRect.decode(row['face'] as String?) ?? _wholeFrame,
          personId: row['person_id'] as String?,
          descriptor: FaceDescriptor.decode(
            row['vector'] as Uint8List?,
            (row['revision'] as num?)?.toInt() ?? 0,
          ),
        ),
    ];
  }

  static const _wholeFrame = FaceRect(0, 0, 1, 1);

  /// Marks every photo as never-looked-at, so the whole library is walked
  /// again from the newest.
  ///
  /// Only the free half. The tags and captions a vendor was paid for stay
  /// exactly where they are, and a suggestion already dismissed
  /// stays dismissed — a rescan that re-billed the library would be the
  /// most expensive button in the app.
  Future<void> forgetFaces() async {
    final db = await _open();
    await db.update(_table, {'people_count': _neverLooked, 'faces': ''});
    await db.delete(_suggestionTable);
    _writes++;
  }

  /// A face count no scan produces — the marker that says "look at this
  /// again", written without dropping the row and the paid work in it.
  static const _neverLooked = -1;

  /// Photos described by a preprocessing step this build no longer uses.
  ///
  /// They have a descriptor, so nothing would ever look at them again —
  /// but it is a vector in a space nothing else lives in, which makes it
  /// worse than none. Handed back so the analyze pass re-opens them.
  Future<Set<String>> staleDescriptorAssets(Set<int> livePipelines) async {
    final db = await _open();
    final placeholders = List.filled(livePipelines.length, '?').join(', ');
    final rows = await db.rawQuery(
      'SELECT DISTINCT local_id FROM $_descriptorTable '
      'WHERE revision / 1000 NOT IN ($placeholders)',
      livePipelines.toList(),
    );
    return {for (final row in rows) row['local_id'] as String};
  }

  /// Photos that already have a *named* face on file — what stops the
  /// backfill going over the same one every pass.
  Future<Set<String>> assetsWithDescriptors() async {
    final db = await _open();
    final rows = await db.query(
      _descriptorTable,
      columns: const ['local_id'],
      where: 'person_id IS NOT NULL',
      distinct: true,
    );
    return {for (final row in rows) row['local_id'] as String};
  }

  /// Whether this person is already in the reference set. What tells a
  /// first confirmation — which makes every unmatched face worth another
  /// look — from a tenth, which doesn't.
  Future<bool> hasDescriptorsFor(String personId) async {
    final db = await _open();
    final rows = await db.query(
      _descriptorTable,
      columns: const ['person_id'],
      where: 'person_id = ?',
      whereArgs: [personId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// The whole reference set, newest confirmation first.
  ///
  /// [perPerson] caps how many are kept per person. It was 12, set when a
  /// descriptor was 2048 floats and every comparison hurt; SFace's are
  /// 128, so forty costs less than twelve used to and each one is another
  /// angle, another light, another year that a future photo can land
  /// near. Newest first, because a face is most like its recent self.
  Future<List<ConfirmedFace>> confirmedFaces({int perPerson = 40}) async {
    final db = await _open();
    return db.transaction((txn) async {
      // Order and cap on the index alone; vectors only for the kept rows
      // (DB-10). One transaction, so the rowids stay put in between.
      final order = await txn.rawQuery(
        'SELECT rowid AS id, person_id FROM $_descriptorTable '
        // Named faces only: an unnamed one is a candidate to search, not
        // a reference to measure against.
        'WHERE person_id IS NOT NULL ORDER BY confirmed_at DESC',
      );
      final kept = <String, int>{};
      final ids = <int>[];
      for (final row in order) {
        final personId = row['person_id'] as String;
        final count = kept[personId] ?? 0;
        if (count >= perPerson) continue;
        kept[personId] = count + 1;
        ids.add((row['id'] as num).toInt());
      }
      final byId = <int, ConfirmedFace>{};
      for (var i = 0; i < ids.length; i += 900) {
        final chunk = ids.skip(i).take(900).toList();
        final rows = await txn.rawQuery(
          'SELECT rowid AS id, local_id, person_id, revision, vector '
          'FROM $_descriptorTable '
          'WHERE rowid IN (${List.filled(chunk.length, '?').join(',')})',
          chunk,
        );
        for (final row in rows) {
          byId[(row['id'] as num).toInt()] = ConfirmedFace(
            personId: row['person_id'] as String,
            localId: row['local_id'] as String,
            descriptor: FaceDescriptor.decode(
              row['vector'] as Uint8List?,
              (row['revision'] as num?)?.toInt() ?? 0,
            ),
          );
        }
      }
      return [for (final id in ids) ?byId[id]];
    });
  }

  /// [confirmedFaces] for one person only — what "find more of them"
  /// searches from.
  Future<List<ConfirmedFace>> confirmedFacesFor(
    String personId, {
    int limit = 40,
  }) async {
    final db = await _open();
    final rows = await db.query(
      _descriptorTable,
      where: 'person_id = ?',
      whereArgs: [personId],
      orderBy: 'confirmed_at DESC',
      limit: limit,
    );
    return [
      for (final row in rows)
        ConfirmedFace(
          personId: personId,
          localId: row['local_id'] as String,
          descriptor: FaceDescriptor.decode(
            row['vector'] as Uint8List?,
            (row['revision'] as num?)?.toInt() ?? 0,
          ),
        ),
    ];
  }

  /// Drops every face, vector and guess of these photos — for hiding. The
  /// paid analysis stays; the face pass looks again if one comes back.
  Future<void> forgetFacesOf(Iterable<String> localIds) =>
      _eachChunk(localIds, (batch, where, ids) {
        batch
          ..delete(_descriptorTable, where: where, whereArgs: ids)
          ..delete(_suggestionTable, where: where, whereArgs: ids)
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
  /// out again and are small, and because which vendor suggestions were
  /// answered is here: losing that re-bills them.
  Future<bool> copyTo(String dest, Set<String> hiddenIds) async => copyDatabase(
    await _open(),
    _factory,
    dest,
    dropIds: hiddenIds,
    scrub: [
      for (final table in [_table, _descriptorTable, _suggestionTable])
        'DELETE FROM $table WHERE local_id IN (SELECT id FROM drop_ids)',
    ],
  );

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<void> clearAll() async {
    final db = await _open();
    final batch = db.batch()
      ..delete(_suggestionTable)
      ..delete(_descriptorTable)
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
      'tags': jsonEncode(analysis.tags),
      'description': analysis.description,
      'reviewed': analysis.reviewed ? 1 : 0,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
    _writes++;
  }

  /// Records what the on-device pass found and nothing else. A whole-row
  /// replace here would wipe a suggestion the user hasn't looked at yet —
  /// the two halves are written by different passes and neither knows what
  /// the other has put there.
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
          'tags': jsonEncode(const <String>[]),
          'description': '',
          'reviewed': 0,
          'faces': encoded,
          'upright': 1,
        }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
      }
      await _carryDescriptors(txn, localId, (old) => carryFaces(old, faces));
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

  /// Answered — kept rather than deleted so the same photo isn't offered
  /// again on the next pass.
  Future<void> markReviewed(String localId) async {
    final db = await _open();
    await db.update(
      _table,
      {'reviewed': 1},
      where: 'local_id = ?',
      whereArgs: [localId],
    );
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
    tags: _tags(row['tags']),
    description: row['description'] as String? ?? '',
    reviewed: (row['reviewed'] as int? ?? 0) == 1,
    legacyBoxes: row['upright'] == 0,
  );

  static List<String> _tags(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List<dynamic>).whereType<String>().toList();
    } catch (_) {
      return const [];
    }
  }
}

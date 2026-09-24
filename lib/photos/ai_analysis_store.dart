import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show Database, DatabaseFactory, OpenDatabaseOptions;

import 'ai_analysis.dart';
import 'face_matcher.dart' show ConfirmedFace, DescribedFace;
import 'on_device_vision.dart' show FaceDescriptor;
import 'person.dart' show FaceRect;

/// Local `sqflite` cache of per-asset AI analysis results, keyed by
/// `AssetRecord.localId` — avoids re-billing OpenAI for a photo already
/// analyzed. See IMPLEMENTATION_PLAN.md T4.4.
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

  /// One row per face the user has confirmed belongs to a person — the
  /// reference set a suggestion is matched against.
  ///
  /// Only confirmed faces. A descriptor is a few kilobytes; one per face
  /// across a real camera roll is hundreds of megabytes, and every one of
  /// them would be a vector with nothing to compare it to.
  static const _descriptorTable = 'face_descriptor';

  /// One row per face the matcher has looked at, named or not.
  static const _suggestionTable = 'face_suggestion';

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path =
        _path ?? p.join(await _factory.getDatabasesPath(), 'ai_analysis.db');
    final db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: (db, version) => db.execute('''
          CREATE TABLE $_table (
            local_id TEXT PRIMARY KEY,
            people_count INTEGER NOT NULL,
            event_label TEXT NOT NULL,
            analyzed_at INTEGER NOT NULL,
            tags TEXT NOT NULL DEFAULT '',
            description TEXT NOT NULL DEFAULT '',
            reviewed INTEGER NOT NULL DEFAULT 0,
            faces TEXT NOT NULL DEFAULT ''
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
        },
      ),
    );
    _db = db;
    return db;
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
  }

  /// Everything the matcher decided, so a newly-named person gets a fresh
  /// hearing on the faces it previously had no opinion about.
  Future<void> clearAllSuggestions() async {
    final db = await _open();
    await db.delete(_suggestionTable);
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
    await db.insert(_descriptorTable, {
      'local_id': localId,
      'face': face.encode(),
      'person_id': personId,
      'revision': descriptor.revision,
      'vector': descriptor.encode(),
      'confirmed_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
  }

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
  /// Only the free half. Tags, captions and event labels a vendor was paid
  /// for stay exactly where they are, and a suggestion already dismissed
  /// stays dismissed — a rescan that re-billed the library would be the
  /// most expensive button in the app.
  Future<void> forgetFaces() async {
    final db = await _open();
    await db.update(_table, {'people_count': _neverLooked, 'faces': ''});
    await db.delete(_suggestionTable);
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
    final rows = await db.query(
      _descriptorTable,
      // Named faces only: an unnamed one is a candidate to search, not a
      // reference to measure against.
      where: 'person_id IS NOT NULL',
      orderBy: 'confirmed_at DESC',
    );
    final kept = <String, int>{};
    final faces = <ConfirmedFace>[];
    for (final row in rows) {
      final personId = row['person_id'] as String;
      final count = kept[personId] ?? 0;
      if (count >= perPerson) continue;
      kept[personId] = count + 1;
      faces.add(
        ConfirmedFace(
          personId: personId,
          localId: row['local_id'] as String,
          descriptor: FaceDescriptor.decode(
            row['vector'] as Uint8List?,
            (row['revision'] as num?)?.toInt() ?? 0,
          ),
        ),
      );
    }
    return faces;
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
  }

  /// This database's file, safe to copy — see the other stores.
  ///
  /// It is in the backup for two reasons that have nothing to do with
  /// each other. The faces and their vectors take hours of the phone's
  /// time to work out again, and they are small: a rectangle is thirty
  /// bytes and an SFace vector five hundred, so a library with four
  /// thousand faces in it costs about two megabytes to keep.
  ///
  /// And the *paid* half lives here too — which vendor suggestions were
  /// already answered. Losing that doesn't cost time, it costs money:
  /// every dismissed photo gets asked about, and billed for, a second
  /// time.
  Future<File?> checkpointedFile() async {
    final db = await _open();
    try {
      await db.execute('PRAGMA wal_checkpoint(FULL)');
    } catch (_) {
      // Not in WAL mode, or a factory that doesn't support the pragma.
    }
    final file = File(db.path);
    return file.existsSync() ? file : null;
  }

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
  }

  Future<void> save(AiPhotoAnalysis analysis) async {
    final db = await _open();
    await db.insert(_table, {
      'local_id': analysis.localId,
      'people_count': analysis.peopleCount,
      'event_label': analysis.eventLabel,
      'analyzed_at': analysis.analyzedAt.millisecondsSinceEpoch,
      'tags': jsonEncode(analysis.tags),
      'description': analysis.description,
      'reviewed': analysis.reviewed ? 1 : 0,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
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
    final updated = await db.update(
      _table,
      {
        'people_count': peopleCount,
        'analyzed_at': analyzedAt.millisecondsSinceEpoch,
        'faces': encoded,
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
    if (updated > 0) return;
    await db.insert(_table, {
      'local_id': localId,
      'people_count': peopleCount,
      'event_label': '',
      'analyzed_at': analyzedAt.millisecondsSinceEpoch,
      'tags': jsonEncode(const <String>[]),
      'description': '',
      'reviewed': 0,
      'faces': encoded,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
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
    return [
      for (final part in value.split(';'))
        if (FaceRect.decode(part) case final rect?) rect,
    ];
  }

  /// The other half: what a vendor call came back with, waiting to be
  /// accepted or thrown away. Leaves the face count alone.
  Future<void> saveSuggestion(AiPhotoAnalysis analysis) async {
    final db = await _open();
    final row = {
      'event_label': analysis.eventLabel,
      'tags': jsonEncode(analysis.tags),
      'description': analysis.description,
      'reviewed': 0,
      'analyzed_at': analysis.analyzedAt.millisecondsSinceEpoch,
    };
    final updated = await db.update(
      _table,
      row,
      where: 'local_id = ?',
      whereArgs: [analysis.localId],
    );
    if (updated > 0) return;
    await db.insert(_table, {
      'local_id': analysis.localId,
      'people_count': analysis.peopleCount,
      ...row,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
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

  /// Suggestions nobody has looked at yet, oldest first — the review list.
  Future<List<AiPhotoAnalysis>> unreviewed() async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: 'reviewed = 0',
      orderBy: 'analyzed_at ASC',
    );
    return [
      for (final row in rows)
        if (_fromRow(row).hasSuggestions) _fromRow(row),
    ];
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
    eventLabel: row['event_label'] as String,
    analyzedAt: DateTime.fromMillisecondsSinceEpoch(row['analyzed_at'] as int),
    tags: _tags(row['tags']),
    description: row['description'] as String? ?? '',
    reviewed: (row['reviewed'] as int? ?? 0) == 1,
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

import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show Database, DatabaseFactory, OpenDatabaseOptions;

import '../backup/change_log.dart';
import '../backup/database_copy.dart';
import 'after_first_frame.dart';
import 'album.dart';
import 'note.dart';

/// Local `sqflite` store for albums and their asset membership. Kept in its
/// own db file (separate from `asset_record_store.dart`) — the two are
/// joined only in application code, by `AssetRecord.localId`.
class AlbumStore {
  AlbumStore({DatabaseFactory? databaseFactory, this._path})
    : _databaseFactory = databaseFactory ?? sqflite.databaseFactory;

  final DatabaseFactory _databaseFactory;
  final String? _path;

  Database? _db;

  static const _albumTable = 'album';
  static const _memberTable = 'album_asset';
  static const _noteTable = 'album_note';

  static const _createNoteTableSql =
      '''
    CREATE TABLE $_noteTable (
      id TEXT PRIMARY KEY,
      album_id TEXT NOT NULL,
      text TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  ''';

  Future<Database>? _opening;

  /// One open at a time: concurrent callers share it.
  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final opening = _opening ??= _openOnce();
    try {
      return await opening;
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  Future<Database> _openOnce() async {
    final path =
        _path ??
        p.join(await _databaseFactory.getDatabasesPath(), 'photo_albums.db');
    final db = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              "ALTER TABLE $_albumTable ADD COLUMN description TEXT NOT NULL DEFAULT ''",
            );
            await db.execute(
              "ALTER TABLE $_albumTable ADD COLUMN tags TEXT NOT NULL DEFAULT '[]'",
            );
          }
          if (oldVersion < 3) {
            await db.execute(
              'ALTER TABLE $_albumTable ADD COLUMN cover_local_id TEXT',
            );
          }
          if (oldVersion < 4) await db.execute(_createNoteTableSql);
        },
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE $_albumTable (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              is_demo INTEGER NOT NULL DEFAULT 0,
              description TEXT NOT NULL DEFAULT '',
              tags TEXT NOT NULL DEFAULT '[]',
              cover_local_id TEXT,
              created_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE $_memberTable (
              album_id TEXT NOT NULL,
              local_id TEXT NOT NULL,
              added_at INTEGER NOT NULL,
              PRIMARY KEY (album_id, local_id)
            )
          ''');
          await db.execute(_createNoteTableSql);
        },
      ),
    );
    // A wiped membership is zeroed, not left in a free page.
    await db.rawQuery(
      'PRAGMA secure_delete = ON',
    ); // Returns a row: execute fails on iOS.
    // After the migrations, never inside them: a trigger has to describe
    // the schema the app just finished upgrading to.
    await installChangeLog(db, const [_albumTable, _memberTable, _noteTable]);
    await db.execute(
      'CREATE INDEX IF NOT EXISTS album_asset_local ON $_memberTable (local_id)',
    );
    _db = db;
    // Zeroed (no `fast`): memberships of hidden photos are logged here.
    unawaited(afterFirstFrame().then((_) => pruneChangeLog(db)));
    return db;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _opening = null;
  }

  /// Empties this database. The log goes last, after the deletes above
  /// have fired their triggers into it — see [AssetRecordStore.clearAll].
  Future<void> clearAll() async {
    final db = await _open();
    final batch = db.batch()
      ..delete(_memberTable)
      ..delete(_noteTable)
      ..delete(_albumTable)
      ..delete(changeLogTable);
    await batch.commit(noResult: true);
  }

  /// A compact copy at [dest] without [hiddenIds]' memberships or covers.
  Future<bool> copyTo(
    String dest,
    Set<String> hiddenIds, {
    bool slim = false,
  }) async => copyDatabase(
    await _open(),
    _databaseFactory,
    dest,
    dropIds: hiddenIds,
    scrub: [
      'DELETE FROM $_memberTable WHERE local_id IN (SELECT id FROM drop_ids)',
      'UPDATE $_albumTable SET cover_local_id = NULL '
          'WHERE cover_local_id IN (SELECT id FROM drop_ids)',
      if (slim) changeLogTailScrub,
    ],
  );

  /// How far this database's change log has got. See `change_log.dart`.
  Future<int> changeMark() async => changeLogMark(await _open());

  /// Equal to an earlier one only while nothing here was written: every
  /// table is logged, so the mark moves with any write, from any
  /// instance. The connection too, so a file reopened from scratch
  /// never matches.
  Future<Object> changeStamp() async {
    final db = await _open();
    return (db, await changeLogMark(db));
  }

  /// The tail of this database's change log, for the copy in the backup.
  Future<List<Map<String, Object?>>> changeLogRows({
    bool decode = true,
  }) async => changeLogTail(await _open(), decode: decode);

  /// Inserts an album under [id] if it isn't tracked yet; no-op otherwise —
  /// so re-seeding a demo album after it's deleted, or re-adding one already
  /// present, never duplicates it.
  Future<Album> upsert({required String id, required String name}) async {
    final db = await _open();
    final existing = await getById(id);
    if (existing != null) return existing;

    final now = DateTime.now();
    await db.insert(_albumTable, {
      'id': id,
      'name': name,
      'created_at': now.millisecondsSinceEpoch,
    });
    return Album(id: id, name: name, createdAt: now);
  }

  Future<Album?> getById(String id) async {
    final db = await _open();
    final rows = await db.query(
      _albumTable,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.single);
  }

  Future<List<Album>> listAll() async {
    final db = await _open();
    final rows = await db.query(_albumTable, orderBy: 'created_at ASC');
    return rows.map(_fromRow).toList();
  }

  /// Adds [localIds] to [albumId] — already-present ones are left alone.
  Future<void> addAssets(String albumId, Iterable<String> localIds) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final localId in localIds) {
      batch.insert(_memberTable, {
        'album_id': albumId,
        'local_id': localId,
        'added_at': now,
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  Future<void> removeAsset(String albumId, String localId) async {
    final db = await _open();
    await db.delete(
      _memberTable,
      where: 'album_id = ? AND local_id = ?',
      whereArgs: [albumId, localId],
    );
  }

  /// [removeAsset] for many, in one batch.
  Future<void> removeAssets(String albumId, Iterable<String> localIds) async {
    final db = await _open();
    final batch = db.batch();
    for (final chunk in _chunks(localIds.toList())) {
      final marks = List.filled(chunk.length, '?').join(',');
      batch.delete(
        _memberTable,
        where: 'album_id = ? AND local_id IN ($marks)',
        whereArgs: [albumId, ...chunk],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Drops [localIds] from every album, and as a cover — photos deleted
  /// for good. One batch, however many.
  Future<void> forgetAssets(Iterable<String> localIds) async {
    final db = await _open();
    final batch = db.batch();
    for (final chunk in _chunks(localIds.toList())) {
      final marks = List.filled(chunk.length, '?').join(',');
      batch
        ..delete(_memberTable, where: 'local_id IN ($marks)', whereArgs: chunk)
        ..update(
          _albumTable,
          {'cover_local_id': null},
          where: 'cover_local_id IN ($marks)',
          whereArgs: chunk,
        );
    }
    await batch.commit(noResult: true);
  }

  /// Under SQLite's bound-parameter limit.
  static Iterable<List<String>> _chunks(List<String> ids) sync* {
    for (var i = 0; i < ids.length; i += 500) {
      yield ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
    }
  }

  Future<List<String>> localIdsIn(String albumId) async {
    final db = await _open();
    final rows = await db.query(
      _memberTable,
      columns: ['local_id'],
      where: 'album_id = ?',
      whereArgs: [albumId],
    );
    return rows.map((r) => r['local_id'] as String).toList();
  }

  /// The albums one photo is in, in one query.
  Future<Set<String>> albumIdsContaining(String localId) async {
    final db = await _open();
    final rows = await db.query(
      _memberTable,
      columns: ['album_id'],
      where: 'local_id = ?',
      whereArgs: [localId],
    );
    return {for (final row in rows) row['album_id'] as String};
  }

  /// Every album's members in one query, by album id — for callers that
  /// would otherwise ask [localIdsIn] once per album.
  Future<Map<String, List<String>>> allMemberships() async {
    final db = await _open();
    final rows = await db.query(
      _memberTable,
      columns: ['album_id', 'local_id'],
    );
    final byAlbum = <String, List<String>>{};
    for (final row in rows) {
      byAlbum
          .putIfAbsent(row['album_id'] as String, () => [])
          .add(row['local_id'] as String);
    }
    return byAlbum;
  }

  /// Membership rows whose album no longer exists, from before [remove]
  /// deleted them together.
  Future<void> dropMembersOfMissingAlbums() async {
    final db = await _open();
    await db.rawDelete(
      'DELETE FROM $_memberTable '
      'WHERE album_id NOT IN (SELECT id FROM $_albumTable)',
    );
  }

  /// Deletes the album itself and its membership rows — the assets it
  /// contained are untouched (they live in `asset_record`, not here).
  Future<void> remove(String albumId) async {
    final db = await _open();
    final batch = db.batch()
      ..delete(_memberTable, where: 'album_id = ?', whereArgs: [albumId])
      ..delete(_noteTable, where: 'album_id = ?', whereArgs: [albumId])
      ..delete(_albumTable, where: 'id = ?', whereArgs: [albumId]);
    await batch.commit(noResult: true);
  }

  String newId() => const Uuid().v4();

  /// [albumId]'s notes, newest first.
  Future<List<Note>> notes(String albumId) async {
    final db = await _open();
    final rows = await db.query(
      _noteTable,
      where: 'album_id = ?',
      whereArgs: [albumId],
      orderBy: 'created_at DESC',
    );
    return [
      for (final row in rows)
        Note(
          id: row['id'] as String,
          text: row['text'] as String,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            row['created_at'] as int,
          ),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            row['updated_at'] as int,
          ),
        ),
    ];
  }

  Future<void> putNote(String albumId, Note note) async {
    final db = await _open();
    await db.insert(_noteTable, {
      'id': note.id,
      'album_id': albumId,
      'text': note.text,
      'created_at': note.createdAt.millisecondsSinceEpoch,
      'updated_at': note.updatedAt.millisecondsSinceEpoch,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
  }

  Future<void> removeNote(String id) async {
    final db = await _open();
    await db.delete(_noteTable, where: 'id = ?', whereArgs: [id]);
  }

  /// [albumId]'s notes as a [NoteBook].
  NoteBook noteBook(String albumId) => AlbumNoteBook(this, albumId);

  /// Renames, re-describes and re-tags — the album's own metadata, none of
  /// which touches what's in it.
  Future<void> update(Album album) async {
    final db = await _open();
    await db.update(
      _albumTable,
      {
        'name': album.name,
        'description': album.description,
        'tags': jsonEncode(album.tags),
        'cover_local_id': album.coverLocalId,
      },
      where: 'id = ?',
      whereArgs: [album.id],
    );
  }

  /// Every distinct tag used on an album — the picker's "select if exists"
  /// list, kept apart from photo tags because they name different things.
  Future<Set<String>> allTags() async {
    final db = await _open();
    final rows = await db.query(_albumTable, columns: ['tags']);
    return {
      for (final row in rows)
        ...(jsonDecode(row['tags'] as String? ?? '[]') as List<dynamic>)
            .cast<String>(),
    };
  }

  static Album _fromRow(Map<String, Object?> row) => Album(
    id: row['id'] as String,
    name: row['name'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    description: row['description'] as String? ?? '',
    tags: (jsonDecode(row['tags'] as String? ?? '[]') as List<dynamic>)
        .cast<String>(),
    coverLocalId: row['cover_local_id'] as String?,
  );
}

class AlbumNoteBook implements NoteBook {
  AlbumNoteBook(this._store, this._albumId);

  final AlbumStore _store;
  final String _albumId;

  @override
  Future<List<Note>> list() => _store.notes(_albumId);

  @override
  Future<Note> save(String text, {Note? existing}) async {
    // Milliseconds, as stored, so what this returns is what [list] reads.
    final now = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
    );
    final note = Note(
      id: existing?.id ?? _store.newId(),
      text: text,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await _store.putNote(_albumId, note);
    return note;
  }

  @override
  Future<void> delete(String id) => _store.removeNote(id);
}

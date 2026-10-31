import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../backup/database_copy.dart';
import 'checkpoint.dart';
import 'merge.dart';
import 'op.dart';
import 'segment.dart';
import 'translate.dart';

/// `sync.db`: this phone's side of the cloud log — its device id and clock,
/// edits not yet sealed (`outbox`), sealed segments not yet in the bucket
/// (`sealed`), and the merge state one entity per row (`entity`), read and
/// written only for the entities an op touches, never the whole library.
///
/// Backed up as a blob by `DataFiles`. A restore never takes the old
/// device id (two phones writing one log would collide); its unsent edits
/// are queued again under this phone's own ([mergeFrom]).
class SyncStore {
  SyncStore({DatabaseFactory? databaseFactory, String? path})
    : this._(databaseFactory, path);

  SyncStore._(this._databaseFactory, this._path);

  final DatabaseFactory? _databaseFactory;
  DatabaseFactory get _factory => _databaseFactory ?? sqflite.databaseFactory;
  final String? _path;

  static const fileName = 'sync.db';

  /// SQLite's bound-variable limit is 999 on older builds.
  static const _chunk = 500;

  Database? _db;
  Future<Database>? _opening;

  Future<Database> open() async {
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
    final path = _path ?? p.join(await _factory.getDatabasesPath(), fileName);
    final db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 1, onCreate: _create),
    );
    final device = await db.rawQuery("SELECT v FROM meta WHERE k = 'device'");
    if (device.isEmpty) {
      await db.insert('meta', {'k': 'device', 'v': const Uuid().v4()});
    }
    return _db = db;
  }

  static Future<void> _create(Database db, int version) async {
    final batch = db.batch()
      ..execute('CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)')
      ..execute('''
        CREATE TABLE outbox (
          n INTEGER PRIMARY KEY AUTOINCREMENT,
          change TEXT NOT NULL
        )
      ''')
      ..execute(
        'CREATE TABLE sealed (seq INTEGER PRIMARY KEY, bytes BLOB NOT NULL)',
      )
      ..execute('''
        CREATE TABLE entity (
          k TEXT PRIMARY KEY,
          line TEXT NOT NULL,
          conflicted INTEGER NOT NULL DEFAULT 0
        )
      ''')
      ..execute(
        'CREATE INDEX entity_conflicted ON entity (conflicted) WHERE conflicted = 1',
      )
      ..execute('CREATE TABLE rev (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)')
      ..execute('INSERT INTO rev (id, n) VALUES (1, 0)');
    await batch.commit(noResult: true);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<String> device() async => (await meta('device'))!;

  Future<String?> meta(String k) async {
    final rows = await (await open()).rawQuery(
      'SELECT v FROM meta WHERE k = ?',
      [k],
    );
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  static Map<String, Object?> _metaRow(String k, Object v) => {
    'k': k,
    'v': v is String ? v : jsonEncode(v),
  };

  static void putMeta(Batch batch, String k, Object v) => batch.insert(
    'meta',
    _metaRow(k, v),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  static Future<void> _bump(DatabaseExecutor db) =>
      db.rawUpdate('UPDATE rev SET n = n + 1 WHERE id = 1');

  Future<void> setMeta(String k, Object v) async {
    final db = await open();
    await db.transaction((txn) async {
      await txn.insert(
        'meta',
        _metaRow(k, v),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await _bump(txn);
    });
  }

  // Outbox.

  static String _encodeChange(Change c) => jsonEncode({
    'e': c.e,
    'id': c.id,
    'o': c.o.name,
    if (c.f != null) 'f': c.f,
    'x': c.x,
  });

  static Change _decodeChange(String s) {
    final j = jsonDecode(s) as Map<String, Object?>;
    return Change(
      j['e'] as String,
      j['id'] as String,
      OpKind.values.byName(j['o'] as String),
      f: j['f'] as String?,
      x: j['x'],
    );
  }

  Future<void> addChanges(List<Change> changes) async {
    if (changes.isEmpty) return;
    final db = await open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final c in changes) {
        batch.insert('outbox', {'change': _encodeChange(c)});
      }
      await batch.commit(noResult: true);
      await _bump(txn);
    });
  }

  Future<List<(int, Change)>> outbox() async => [
    for (final r in await (await open()).rawQuery(
      'SELECT n, change FROM outbox ORDER BY n',
    ))
      (r['n'] as int, _decodeChange(r['change'] as String)),
  ];

  Future<int> waiting() async {
    final db = await open();
    final o = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM outbox'),
    );
    final s = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM sealed'),
    );
    return (o ?? 0) + (s ?? 0);
  }

  // Sealed segments.

  Future<List<(int, List<int>)>> sealed() async => [
    for (final r in await (await open()).rawQuery(
      'SELECT seq, bytes FROM sealed ORDER BY seq',
    ))
      (r['seq'] as int, r['bytes'] as List<int>),
  ];

  Future<void> dropSealed(int seq) async {
    final db = await open();
    await db.delete('sealed', where: 'seq = ?', whereArgs: [seq]);
  }

  // Merge state.

  /// The stored lines of [keys] read into [into]. Keys with no row are left out.
  Future<void> loadInto(SyncState into, Iterable<String> keys) async {
    final db = await open();
    final want = keys.where((k) => !into.entities.containsKey(k)).toList();
    for (var i = 0; i < want.length; i += _chunk) {
      final part = want.sublist(i, (i + _chunk).clamp(0, want.length));
      final rows = await db.query(
        'entity',
        columns: ['line'],
        where: 'k IN (${List.filled(part.length, '?').join(',')})',
        whereArgs: part,
      );
      for (final r in rows) {
        Checkpoint.readEntityLine(into, r['line'] as String);
      }
    }
  }

  /// Writes what [state] touched plus [meta], and runs [also], in one
  /// transaction: a crash keeps all of it or none.
  Future<void> save(
    SyncState state, {
    Map<String, Object> meta = const {},
    void Function(Batch batch)? also,
  }) async {
    final db = await open();
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final key in state.touched) {
        final ent = state.entities[key];
        if (ent == null) continue;
        final conflicted = ent.heads.values.any((h) => h.length > 1);
        batch.insert('entity', {
          'k': key,
          'line': Checkpoint.entityLine(ent),
          'conflicted': conflicted ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      meta.forEach((k, v) => putMeta(batch, k, v));
      also?.call(batch);
      await batch.commit(noResult: true);
      await _bump(txn);
    });
    state.touched.clear();
  }

  /// Every entity with an open conflict, read into a fresh state.
  Future<SyncState> conflicted() async {
    final s = SyncState();
    for (final r in await (await open()).rawQuery(
      'SELECT line FROM entity WHERE conflicted = 1',
    )) {
      Checkpoint.readEntityLine(s, r['line'] as String);
    }
    return s..touched.clear();
  }

  /// Streams every entity line, a page at a time: for writing a checkpoint
  /// without holding the library in memory.
  Stream<String> allLines({int page = 2000}) async* {
    final db = await open();
    var after = '';
    while (true) {
      final rows = await db.rawQuery(
        'SELECT k, line FROM entity WHERE k > ? ORDER BY k LIMIT ?',
        [after, page],
      );
      if (rows.isEmpty) return;
      for (final r in rows) {
        yield r['line'] as String;
      }
      after = rows.last['k'] as String;
    }
  }

  /// Replaces the merge state with [lines] (a downloaded checkpoint), keeping
  /// this device's id, clock and anything not yet sent.
  Future<void> adopt(Iterable<String> lines, Map<String, int> vv) async {
    final db = await open();
    await db.transaction((txn) async {
      await txn.delete('entity');
      var batch = txn.batch();
      var n = 0;
      for (final line in lines) {
        final j = jsonDecode(line) as Map<String, Object?>;
        final heads = (j['heads'] as Map).values;
        batch.insert('entity', {
          'k': '${j['e']}/${j['id']}',
          'line': line,
          'conflicted': heads.any((h) => (h as List).length > 1) ? 1 : 0,
        });
        if (++n % 1000 == 0) {
          await batch.commit(noResult: true);
          batch = txn.batch();
        }
      }
      putMeta(batch, 'vv', vv);
      putMeta(batch, 'checkpoint', true);
      await batch.commit(noResult: true);
      await _bump(txn);
    });
  }

  // Backup.

  Future<bool> copyTo(String dest) async =>
      copyDatabase(await open(), _factory, dest);

  /// From a backed-up `sync.db`: its edits that never reached the bucket
  /// (outbox and sealed segments), queued again under this phone's device
  /// id. Nothing else: the merge state comes back from the bucket itself.
  Future<int> mergeFrom(String path) async {
    final old = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
    final changes = <Change>[];
    try {
      final oldDevice = (await old.rawQuery(
        "SELECT v FROM meta WHERE k = 'device'",
      )).firstOrNull?['v'];
      if (oldDevice == await device()) return 0;
      for (final r in await old.rawQuery(
        'SELECT bytes FROM sealed ORDER BY seq',
      )) {
        final seg = Segment.decode(r['bytes'] as List<int>, lastModified: 0);
        for (final op in seg.ops) {
          changes.add(Change(op.e, op.id, op.o, f: op.f, x: op.x));
        }
      }
      for (final r in await old.rawQuery(
        'SELECT change FROM outbox ORDER BY n',
      )) {
        changes.add(_decodeChange(r['change'] as String));
      }
    } finally {
      await old.close();
    }
    await addChanges(changes);
    return changes.length;
  }

  /// Moves on every write.
  Future<int> dataMark() async {
    final rows = await (await open()).rawQuery(
      'SELECT n FROM rev WHERE id = 1',
    );
    return rows.first['n'] as int;
  }
}

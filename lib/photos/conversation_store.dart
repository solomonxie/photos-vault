import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show ConflictAlgorithm, Database, DatabaseFactory, OpenDatabaseOptions;

import '../backup/database_copy.dart';
import 'chat_voice.dart';
import 'conversation_file.dart';
import 'person_store.dart';

/// One conversation of a person's: a chat id and where it came from.
class ConversationChat {
  const ConversationChat(this.chat, this.source, this.count);
  final String chat;
  final String source;
  final int count;
}

/// Local `sqflite` store of imported chat history, one row per message,
/// keyed by its [ConversationMessage.hash] so a re-import adds nothing.
class ConversationStore {
  ConversationStore({
    DatabaseFactory? databaseFactory,
    String? path,
    ChatVoice? voice,
  }) : this._(databaseFactory, path, voice);

  ConversationStore._(this._databaseFactory, this._path, this._voice);

  final ChatVoice? _voice;

  /// Resolved on first use: the global factory throws where there's no
  /// `sqflite` (a widget test).
  final DatabaseFactory? _databaseFactory;
  DatabaseFactory get _factory => _databaseFactory ?? sqflite.databaseFactory;
  final String? _path;

  static const _table = 'message';

  /// People whose messages changed since their First met / Last seen were
  /// last moved: the only ones [applyConversationSpans] looks at.
  static const _pending = 'span_pending';
  static const _chunk = 1000;

  Database? _db;
  Future<Database>? _opening;

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
        _path ?? p.join(await _factory.getDatabasesPath(), 'conversations.db');
    final db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 5,
        onUpgrade: (db, from, to) async {
          if (from < 2) {
            await _createPending(db);
            await db.execute(
              'INSERT OR IGNORE INTO $_pending SELECT DISTINCT person_id FROM $_table',
            );
          }
          if (from < 4) {
            await db.execute('ALTER TABLE $_table ADD COLUMN thumb BLOB');
          }
          if (from < 5) {
            await db.execute('ALTER TABLE $_table ADD COLUMN voice TEXT');
            await db.execute('ALTER TABLE $_table ADD COLUMN voice_ms INTEGER');
          }
          if (from == 3) {
            // v3 kept thumbnails as files; none were ever imported that way.
            await db.execute('ALTER TABLE $_table DROP COLUMN media');
          }
        },
        onCreate: (db, version) async {
          await _createPending(db);
          await db.execute('''
            CREATE TABLE $_table (
              person_id TEXT NOT NULL,
              chat TEXT NOT NULL,
              source TEXT NOT NULL,
              at INTEGER NOT NULL,
              from_me INTEGER NOT NULL,
              sender TEXT NOT NULL,
              text TEXT NOT NULL,
              kind TEXT NOT NULL,
              hash TEXT PRIMARY KEY,
              thumb BLOB,
              voice TEXT,
              voice_ms INTEGER
            )
          ''');
          await db.execute(
            'CREATE INDEX message_person_at ON $_table (person_id, at)',
          );
        },
      ),
    );
    return _db = db;
  }

  static Future<void> _createPending(sqflite.DatabaseExecutor db) =>
      db.execute('CREATE TABLE $_pending (person_id TEXT PRIMARY KEY)');

  static Future<void> _flag(sqflite.DatabaseExecutor db, String personId) =>
      db.insert(_pending, {
        'person_id': personId,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<void> close() async {
    final db = _db;
    _db = null;
    await db?.close();
  }

  /// Adds [messages] to [personId], a transaction per thousand; returns
  /// how many were new. [onProgress] gets the count written so far.
  Future<int> insert(
    String personId,
    List<ConversationMessage> messages, {
    void Function(int done)? onProgress,
  }) async {
    final db = await _open();
    await (_voice ?? chatVoice).adopt(messages);
    var added = 0;
    for (var i = 0; i < messages.length; i += _chunk) {
      final end = i + _chunk > messages.length ? messages.length : i + _chunk;
      added += await db.transaction((txn) async {
        final before = await _changes(txn);
        final batch = txn.batch();
        for (final m in messages.sublist(i, end)) {
          batch.insert(_table, {
            'person_id': personId,
            'chat': m.chat,
            'source': m.source,
            'at': m.at.millisecondsSinceEpoch,
            'from_me': m.fromMe ? 1 : 0,
            'sender': m.sender,
            'text': m.text,
            'kind': m.kind,
            'hash': m.hash,
            'thumb': m.thumb,
            'voice': m.voice,
            'voice_ms': m.voiceMs,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await batch.commit(noResult: true);
        final added = await _changes(txn) - before;
        if (added > 0) await _flag(txn, personId);
        // A message already here from a text-only import gains its
        // thumbnail, or its clip.
        final thumbs = txn.batch();
        for (final m in messages.sublist(i, end)) {
          if (m.thumb != null) {
            thumbs.update(
              _table,
              {'thumb': m.thumb},
              where: 'hash = ? AND thumb IS NULL',
              whereArgs: [m.hash],
            );
          }
          if (m.voice != null) {
            thumbs.update(
              _table,
              {'voice': m.voice, 'voice_ms': m.voiceMs},
              where: 'hash = ? AND voice IS NULL',
              whereArgs: [m.hash],
            );
          }
        }
        await thumbs.commit(noResult: true);
        return added;
      });
      onProgress?.call(end);
    }
    return added;
  }

  static Future<int> _changes(sqflite.DatabaseExecutor db) async =>
      (await db.rawQuery('SELECT total_changes() AS n')).first['n'] as int;

  /// Messages per person, in one query.
  Future<Map<String, int>> countsByPerson() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT person_id, COUNT(*) AS n FROM $_table GROUP BY person_id',
    );
    return {for (final r in rows) r['person_id'] as String: r['n'] as int};
  }

  /// Each person's chats (`wechat:wxid_…`), from what is already here: how
  /// a re-import knows who a chat is without asking again. One scan.
  Future<Map<String, Set<String>>> chatsByPerson() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT DISTINCT person_id, chat FROM $_table',
    );
    final out = <String, Set<String>>{};
    for (final r in rows) {
      (out[r['person_id'] as String] ??= {}).add(r['chat'] as String);
    }
    return out;
  }

  /// Messages per person per source (qq, wechat…), in one query.
  Future<Map<String, Map<String, int>>> countsBySource() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT person_id, source, COUNT(*) AS n FROM $_table '
      'GROUP BY person_id, source',
    );
    final out = <String, Map<String, int>>{};
    for (final r in rows) {
      (out[r['person_id'] as String] ??= {})[r['source'] as String] =
          r['n'] as int;
    }
    return out;
  }

  Future<int> countFor(String personId) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM $_table WHERE person_id = ?',
      [personId],
    );
    return rows.first['n'] as int;
  }

  /// Messages per local calendar month, as (year, month), in one query.
  Future<Map<(int, int), int>> monthsOf(String personId) async {
    final db = await _open();
    final rows = await db.rawQuery(
      "SELECT strftime('%Y-%m', at / 1000, 'unixepoch', 'localtime') AS ym, "
      'COUNT(*) AS n FROM $_table WHERE person_id = ? GROUP BY ym',
      [personId],
    );
    return {
      for (final r in rows)
        if ((r['ym'] as String).split('-') case [final y, final m])
          (int.parse(y), int.parse(m)): r['n'] as int,
    };
  }

  Future<List<ConversationChat>> chatsOf(String personId) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT chat, source, COUNT(*) AS n FROM $_table '
      'WHERE person_id = ? GROUP BY chat, source ORDER BY n DESC',
      [personId],
    );
    return [
      for (final r in rows)
        ConversationChat(
          r['chat'] as String,
          r['source'] as String,
          r['n'] as int,
        ),
    ];
  }

  /// Newest first, older than [before] (by time, then hash, so a page
  /// boundary inside one second loses nothing).
  Future<List<ConversationMessage>> page(
    String personId, {
    ConversationMessage? before,
    int limit = 200,
    String? kind,
  }) async {
    final db = await _open();
    final rows = await db.query(
      _table,
      where: [
        'person_id = ?',
        if (kind != null) 'kind = ?',
        if (before != null) '(at < ? OR (at = ? AND hash < ?))',
      ].join(' AND '),
      whereArgs: [
        personId,
        ?kind,
        if (before != null) ...[
          before.at.millisecondsSinceEpoch,
          before.at.millisecondsSinceEpoch,
          before.hash,
        ],
      ],
      orderBy: 'at DESC, hash DESC',
      limit: limit,
    );
    return rows.map(_message).toList();
  }

  /// Newest first, text containing [query]; of one [kind] if given.
  Future<List<ConversationMessage>> search(
    String personId,
    String query, {
    int limit = 200,
    String? kind,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final db = await _open();
    final escaped = q.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}');
    final rows = await db.query(
      _table,
      where:
          "person_id = ? AND text LIKE ? ESCAPE '\\'"
          '${kind == null ? '' : ' AND kind = ?'}',
      whereArgs: [personId, '%$escaped%', ?kind],
      orderBy: 'at DESC, hash DESC',
      limit: limit,
    );
    return rows.map(_message).toList();
  }

  /// What's already stored of [chats]: each message's hash, and whether
  /// it still lacks a picture or a clip. A few queries, however many chats.
  Future<Map<String, ({bool noThumb, bool noVoice})>> storedIn(
    Iterable<String> chats,
  ) async {
    final db = await _open();
    final all = chats.toList();
    final out = <String, ({bool noThumb, bool noVoice})>{};
    for (var i = 0; i < all.length; i += 500) {
      final part = all.sublist(i, i + 500 > all.length ? all.length : i + 500);
      final rows = await db.rawQuery(
        'SELECT hash, thumb IS NULL AS nt, voice IS NULL AS nv FROM $_table '
        'WHERE chat IN (${List.filled(part.length, '?').join(',')})',
        part,
      );
      for (final r in rows) {
        out[r['hash'] as String] = (
          noThumb: r['nt'] == 1,
          noVoice: r['nv'] == 1,
        );
      }
    }
    return out;
  }

  /// Whether [personId] has a message at exactly [at].
  Future<bool> hasMessageAt(String personId, DateTime at) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT 1 FROM $_table WHERE person_id = ? AND at = ? LIMIT 1',
      [personId, at.millisecondsSinceEpoch],
    );
    return rows.isNotEmpty;
  }

  /// [personId]'s newest message, or null. Never one dated ahead of now:
  /// an export can carry a bogus future stamp, and Last seen can't be after
  /// today.
  Future<DateTime?> latestFor(String personId) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT MAX(at) AS hi FROM $_table WHERE person_id = ? AND at <= ?',
      [personId, DateTime.now().millisecondsSinceEpoch],
    );
    final ms = rows.firstOrNull?['hi'];
    return ms is int ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  /// Each person's newest message, in one query: part of their Last seen.
  Future<Map<String, DateTime>> latestByPerson() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT person_id, MAX(at) AS hi FROM $_table WHERE at <= ? '
      'GROUP BY person_id',
      [DateTime.now().millisecondsSinceEpoch],
    );
    return {
      for (final r in rows)
        if ((r['person_id'], r['hi']) case (final String id, final int ms))
          id: DateTime.fromMillisecondsSinceEpoch(ms),
    };
  }

  /// Earliest and latest message of each flagged person, in one query.
  Future<Map<String, (DateTime, DateTime)>> pendingSpans() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT m.person_id, MIN(m.at) AS lo, MAX(m.at) AS hi '
      'FROM $_pending p JOIN $_table m ON m.person_id = p.person_id '
      'GROUP BY m.person_id',
    );
    DateTime at(Object? ms) => DateTime.fromMillisecondsSinceEpoch(ms as int);
    return {
      for (final r in rows)
        r['person_id'] as String: (at(r['lo']), at(r['hi'])),
    };
  }

  Future<void> clearPending(Iterable<String> personIds) async {
    final db = await _open();
    final batch = db.batch();
    for (final id in personIds) {
      batch.delete(_pending, where: 'person_id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  /// A consistent copy at [dest], for the backup.
  Future<bool> copyTo(String dest) async =>
      copyDatabase(await _open(), _factory, dest);

  /// Rows of a backed-up copy at [path] added here; a message already here
  /// keeps what it has.
  Future<int> mergeFrom(String path) async =>
      mergeDatabase(await _open(), path);

  /// Moves on an import, a merge, a delete or a thumbnail or clip arriving.
  Future<int> dataMark() async => tablesMark(
    await _open(),
    [_table],
    extra: {_table: 'IFNULL(length(thumb), 0) + IFNULL(voice_ms, 0)'},
  );

  /// Two people merged into one.
  Future<void> movePerson(String from, String to) async {
    final db = await _open();
    await db.transaction((txn) async {
      final moved = await txn.update(
        _table,
        {'person_id': to},
        where: 'person_id = ?',
        whereArgs: [from],
      );
      await txn.delete(_pending, where: 'person_id = ?', whereArgs: [from]);
      if (moved > 0) await _flag(txn, to);
    });
  }

  /// A person deleted takes their conversations with them.
  Future<void> forgetPerson(String personId) async {
    final db = await _open();
    final clips = await db.query(
      _table,
      columns: ['voice'],
      where: 'person_id = ? AND voice IS NOT NULL',
      whereArgs: [personId],
    );
    await db.transaction((txn) async {
      for (final table in [_table, _pending]) {
        await txn.delete(table, where: 'person_id = ?', whereArgs: [personId]);
      }
    });
    for (final r in clips) {
      try {
        await (await (_voice ?? chatVoice).fileFor(r['voice'] as String))
            .delete();
      } on FileSystemException {
        // Already gone.
      }
    }
  }

  static ConversationMessage _message(Map<String, Object?> r) =>
      ConversationMessage(
        chat: r['chat'] as String,
        source: r['source'] as String,
        at: DateTime.fromMillisecondsSinceEpoch(r['at'] as int),
        fromMe: r['from_me'] == 1,
        sender: r['sender'] as String,
        text: r['text'] as String,
        kind: r['kind'] as String,
        hash: r['hash'] as String,
        thumb: r['thumb'] as Uint8List?,
        voice: r['voice'] as String?,
        voiceMs: r['voice_ms'] as int?,
      );
}

/// Best-effort, own handle — as [forgetPersonFaces] does.
Future<void> moveConversations(
  String from,
  String to, {
  ConversationStore? store,
}) async {
  try {
    await (store ?? ConversationStore()).movePerson(from, to);
  } catch (_) {
    // No conversations database — nothing to move.
  }
}

Future<void> forgetConversations(
  String personId, {
  ConversationStore? store,
}) async {
  try {
    await (store ?? ConversationStore()).forgetPerson(personId);
  } catch (_) {
    // No conversations database — nothing to forget.
  }
}

/// Moves each flagged person's First met back and Last seen up to their
/// conversations, then unflags them. Nothing flagged is one empty query.
/// [ConversationStore.latestByPerson], or nothing where there's no chat
/// database (tests).
Future<Map<String, DateTime>> latestChats([ConversationStore? store]) async {
  try {
    return await (store ?? ConversationStore()).latestByPerson();
  } catch (_) {
    return const {};
  }
}

/// True when someone was looked at.
Future<bool> applyConversationSpans(
  PersonStore personStore, {
  ConversationStore? store,
}) async {
  try {
    final conversations = store ?? ConversationStore();
    final spans = await conversations.pendingSpans();
    if (spans.isEmpty) return false;
    final alive = {for (final p in await personStore.listAll()) p.id};
    for (final MapEntry(key: id, value: (lo, _)) in spans.entries) {
      if (!alive.contains(id)) continue;
      await personStore.markMet(id, lo);
    }
    await conversations.clearPending(spans.keys);
    return true;
  } catch (_) {
    // Still flagged: tried again next time.
    return false;
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show Database, DatabaseFactory, OpenDatabaseOptions;
import 'package:uuid/uuid.dart';

import '../backup/change_log.dart';
import '../backup/database_copy.dart';
import '../storage/after_first_frame.dart';
import '../vault/keys.dart' show AlbumKeys;
import 'known_names.dart';
import 'person.dart';
import 'person_detail.dart';

/// Which set a profile write lands in. Required on every write, so no
/// default can drop an edit made inside a sealed set into the open one.
class PersonScope {
  const PersonScope._(this.passcodeHash, this.keys);

  /// The set anybody holding the phone can read.
  static const open = PersonScope._(openNamespace, null);

  /// The set [keys] open, kept under [passcodeHash].
  PersonScope.sealed(String passcodeHash, AlbumKeys keys)
    : this._(passcodeHash, keys);

  /// From a screen's own pair. A sealed hash with no [keys] writes nothing.
  const PersonScope.of(this.passcodeHash, this.keys);

  final String passcodeHash;
  final AlbumKeys? keys;

  bool get isOpen => passcodeHash == openNamespace;
}

/// Local `sqflite` store for [Person] profiles, their tagged-photo
/// membership (same join-table shape as `album_store.dart`), relationships,
/// and location history. See IMPLEMENTATION_PLAN.md Phase 7.
class PersonStore {
  PersonStore({DatabaseFactory? databaseFactory, this._path, Uuid? uuid})
    : _databaseFactory = databaseFactory ?? sqflite.databaseFactory,
      _uuid = uuid ?? const Uuid();

  final DatabaseFactory _databaseFactory;
  final String? _path;
  final Uuid _uuid;
  final _seal = PersonDetailSeal();

  Database? _db;

  static const _personTable = 'person';
  static const _memberTable = 'person_asset';
  static const _relationshipTable = 'person_relationship';
  static const _locationTable = 'person_location';
  static const _historyTable = 'person_history';
  static const _detailTable = 'person_detail';
  static const _eventTable = 'person_event';
  static const _groupTable = 'person_group';

  /// Ids merged into a person. Hidden folders are keyed by person id, so
  /// a merged-away id is how theirs are still found.
  static const _aliasTable = 'person_alias';

  /// Names and handles imports knew someone by. See [KnownAs].
  static const _knownTable = 'person_known_as';

  /// Photo memberships whose person no longer exists.
  Future<void> dropMembersOfMissingPeople() async {
    final db = await _open();
    await db.rawDelete(
      'DELETE FROM $_memberTable '
      'WHERE person_id NOT IN (SELECT id FROM $_personTable)',
    );
  }

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
        _path ?? p.join(await _databaseFactory.getDatabasesPath(), 'people.db');
    final db = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 10,
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              'ALTER TABLE $_relationshipTable ADD COLUMN organization TEXT',
            );
          }
          if (oldVersion < 3) {
            await db.execute(_createHistoryTableSql);
          }
          if (oldVersion < 5) {
            await db.execute(
              'ALTER TABLE $_personTable ADD COLUMN avatar_face TEXT',
            );
          }
          if (oldVersion < 6) {
            await db.execute(_createDetailTableSql);
            for (final table in const [
              _relationshipTable,
              _locationTable,
              _historyTable,
            ]) {
              await db.execute(
                "ALTER TABLE $table "
                "ADD COLUMN passcode_hash TEXT NOT NULL DEFAULT ''",
              );
            }
            await _moveDetailOutOfPersonRows(db);
          }
          // After 6, deliberately: the rebuild below copies the column that
          // step adds.
          if (oldVersion < 7) {
            for (final table in const [_locationTable, _historyTable]) {
              await db.execute(
                "ALTER TABLE $table ADD COLUMN payload TEXT NOT NULL "
                "DEFAULT ''",
              );
            }
            await _widenRelationshipKey(db);
          }
          if (oldVersion < 8) {
            await db.execute(_createEventTableSql);
          }
          if (oldVersion < 9) {
            await db.execute(_createGroupTableSql);
          }
          // v10: "who is in this photo" without a full scan (DB-10).
          if (oldVersion < 10) await db.execute(_createMemberIndexSql);
          if (oldVersion < 4) {
            await db.execute(
              'ALTER TABLE $_personTable ADD COLUMN birth_date INTEGER',
            );
            await db.execute(
              'ALTER TABLE $_personTable ADD COLUMN gender TEXT',
            );
            await db.execute(
              "ALTER TABLE $_personTable ADD COLUMN custom_fields TEXT NOT NULL DEFAULT '[]'",
            );
            // A device already at v3 has $_historyTable without these —
            // one already at v2 got it fresh (with them) from the v2->v3
            // step just above, so this is a no-op there.
            if (oldVersion >= 3) {
              await db.execute(
                "ALTER TABLE $_historyTable ADD COLUMN titles TEXT NOT NULL DEFAULT '[]'",
              );
              await db.execute(
                "ALTER TABLE $_historyTable ADD COLUMN projects TEXT NOT NULL DEFAULT '[]'",
              );
              await db.execute(
                "ALTER TABLE $_historyTable ADD COLUMN awards TEXT NOT NULL DEFAULT '[]'",
              );
            }
          }
        },
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE $_personTable (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              avatar_local_id TEXT,
              avatar_face TEXT,
              bio TEXT NOT NULL DEFAULT '',
              birth_date INTEGER,
              gender TEXT,
              custom_fields TEXT NOT NULL DEFAULT '[]',
              locked INTEGER NOT NULL DEFAULT 0,
              passcode_hash TEXT,
              passcode_hint TEXT,
              is_demo INTEGER NOT NULL DEFAULT 0,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE $_memberTable (
              person_id TEXT NOT NULL,
              local_id TEXT NOT NULL,
              added_at INTEGER NOT NULL,
              PRIMARY KEY (person_id, local_id)
            )
          ''');
          await db.execute('''
            CREATE TABLE $_relationshipTable (
              person_id TEXT NOT NULL,
              related_person_id TEXT NOT NULL,
              type TEXT NOT NULL,
              organization TEXT,
              created_at INTEGER NOT NULL,
              passcode_hash TEXT NOT NULL DEFAULT '',
              payload TEXT NOT NULL DEFAULT '',
              PRIMARY KEY (person_id, related_person_id, passcode_hash)
            )
          ''');
          await db.execute('''
            CREATE TABLE $_locationTable (
              id TEXT PRIMARY KEY,
              person_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              place TEXT NOT NULL,
              since INTEGER NOT NULL,
              passcode_hash TEXT NOT NULL DEFAULT '',
              payload TEXT NOT NULL DEFAULT ''
            )
          ''');
          await db.execute(_createHistoryTableSql);
          await db.execute(_createDetailTableSql);
          await db.execute(_createEventTableSql);
          await db.execute(_createGroupTableSql);
          await db.execute(_createMemberIndexSql);
        },
      ),
    );
    // After the migrations, never inside them: a trigger has to describe
    // the schema the app just finished upgrading to.
    await db.rawQuery(
      'PRAGMA secure_delete = ON',
    ); // Returns a row: execute fails on iOS.
    // Added in place, not by a version step: a column with a default is
    // all an older row needs.
    final personColumns = {
      for (final c in await db.rawQuery('PRAGMA table_info($_personTable)'))
        c['name'] as String,
    };
    for (final column in const ['first_name', 'middle_name', 'last_name']) {
      if (!personColumns.contains(column)) {
        await db.execute(
          "ALTER TABLE $_personTable ADD COLUMN $column TEXT NOT NULL DEFAULT ''",
        );
      }
    }
    // Whether a photo is on someone because one of its faces was named
    // them: taking the name off the face takes it off them, and only then.
    if (!(await db.rawQuery('PRAGMA table_info($_memberTable)'))
        .any((c) => c['name'] == 'via_face')) {
      await db.execute(
        'ALTER TABLE $_memberTable ADD COLUMN via_face INTEGER NOT NULL DEFAULT 0',
      );
    }
    await db.execute(
      'CREATE TABLE IF NOT EXISTS $_aliasTable '
      '(alias_id TEXT PRIMARY KEY, person_id TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS $_knownTable (person_id TEXT NOT NULL, '
      'kind TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, '
      'added_at INTEGER NOT NULL, PRIMARY KEY (person_id, kind, key))',
    );
    await _installPersonChanges(db);
    await installChangeLog(
      db,
      const [
        _personTable,
        _memberTable,
        _relationshipTable,
        _locationTable,
        _historyTable,
        _detailTable,
        _eventTable,
        _groupTable,
        _knownTable,
      ],
      private: {
        for (final table in [_personTable, ..._sealedTables])
          table: _privateRowSql,
      },
    );
    _db = db;
    // Zeroed (no `fast`): memberships of hidden photos are logged here.
    unawaited(
      afterFirstFrame().then((_) async {
        await _purgePrivateLog(db);
        await _joinSameNameGroups(db);
        await pruneChangeLog(db);
      }),
    );
    return db;
  }

  static const _createMemberIndexSql =
      'CREATE INDEX IF NOT EXISTS person_asset_local '
      'ON $_memberTable (local_id)';

  /// A row kept under a passcode, as the change log tests it.
  static const _privateRowSql = "COALESCE({row}.passcode_hash, '') != ''";

  /// Every change to a person's open profile, kept for good: their own
  /// history to read back, unlike the backup change log, which keeps only
  /// the newest few thousand of everything. Written by triggers, so no
  /// write path can forget to. Sealed rows are never logged.
  static const _changeTable = 'person_change';
  static const _muteTable = 'person_change_mute';

  static const _nowMs =
      "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)";

  /// Edits to one field this close together are one change: the profile
  /// saves on every keystroke.
  static const _coalesceMs = 120000;

  static String _trigger(
    String table,
    String op,
    String kind, {
    required String person,
    String before = 'NULL',
    String after = 'NULL',
    String when = '1',
    bool coalesce = false,
    String? of,
  }) {
    final name = 'pc_${table}_${op.toLowerCase()}_$kind';
    final event = of == null ? op : '$op OF $of';
    final recent =
        'SELECT seq FROM $_changeTable WHERE seq = '
        '(SELECT MAX(seq) FROM $_changeTable WHERE person_id = $person) '
        "AND kind = '$kind' AND at > $_nowMs - $_coalesceMs";
    final body = coalesce
        ? 'UPDATE $_changeTable SET after = $after, at = $_nowMs '
              'WHERE seq IN ($recent); '
              'INSERT INTO $_changeTable (person_id, at, kind, before, after) '
              "SELECT $person, $_nowMs, '$kind', $before, $after "
              'WHERE NOT EXISTS ($recent);'
        : 'INSERT INTO $_changeTable (person_id, at, kind, before, after) '
              "VALUES ($person, $_nowMs, '$kind', $before, $after);";
    return 'CREATE TRIGGER $name AFTER $event ON $table '
        'WHEN NOT EXISTS (SELECT 1 FROM $_muteTable) AND ($when) '
        'BEGIN $body END';
  }

  static String _openRow(String row) => "COALESCE($row.passcode_hash, '') = ''";

  static String _eventJson(String row) =>
      "json_object('type', $row.type, 'at', $row.at, 'notes', $row.notes)";

  static final _changeTriggers = [
    _trigger(
      _personTable,
      'INSERT',
      'created',
      person: 'NEW.id',
      after: 'NEW.name',
    ),
    _trigger(
      _personTable,
      'UPDATE',
      'name',
      person: 'NEW.id',
      of: 'name',
      before: 'OLD.name',
      after: 'NEW.name',
      when: 'OLD.name IS NOT NEW.name',
      coalesce: true,
    ),
    _trigger(
      _personTable,
      'UPDATE',
      'name_parts',
      person: 'NEW.id',
      before:
          "json_object('first', OLD.first_name, 'middle', OLD.middle_name, "
          "'last', OLD.last_name)",
      after:
          "json_object('first', NEW.first_name, 'middle', NEW.middle_name, "
          "'last', NEW.last_name)",
      when:
          'OLD.first_name IS NOT NEW.first_name OR '
          'OLD.middle_name IS NOT NEW.middle_name OR '
          'OLD.last_name IS NOT NEW.last_name',
      coalesce: true,
    ),
    _trigger(
      _personTable,
      'UPDATE',
      'picture',
      person: 'NEW.id',
      of: 'avatar_local_id',
      when: 'OLD.avatar_local_id IS NOT NEW.avatar_local_id',
    ),
    _trigger(
      _personTable,
      'UPDATE',
      'locked',
      person: 'NEW.id',
      of: 'locked',
      after: 'NEW.locked',
      when: 'OLD.locked IS NOT NEW.locked',
    ),
    _trigger(
      _memberTable,
      'INSERT',
      'photo_added',
      person: 'NEW.person_id',
      after: 'NEW.local_id',
    ),
    _trigger(
      _memberTable,
      'DELETE',
      'photo_removed',
      person: 'OLD.person_id',
      before: 'OLD.local_id',
    ),
    _trigger(
      _detailTable,
      'INSERT',
      'details',
      person: 'NEW.person_id',
      after: 'NEW.payload',
      when: "NEW.passcode_hash = ''",
      coalesce: true,
    ),
    _trigger(
      _detailTable,
      'UPDATE',
      'details',
      person: 'NEW.person_id',
      before: 'OLD.payload',
      after: 'NEW.payload',
      when: "NEW.passcode_hash = '' AND OLD.payload IS NOT NEW.payload",
      coalesce: true,
    ),
    _trigger(
      _groupTable,
      'INSERT',
      'group_joined',
      person: 'NEW.person_id',
      after: 'NEW.name',
      when: _openRow('NEW'),
    ),
    _trigger(
      _groupTable,
      'DELETE',
      'group_left',
      person: 'OLD.person_id',
      before: 'OLD.name',
      when: _openRow('OLD'),
    ),
    _trigger(
      _eventTable,
      'INSERT',
      'event_added',
      person: 'NEW.person_id',
      after: _eventJson('NEW'),
      when: _openRow('NEW'),
    ),
    _trigger(
      _eventTable,
      'UPDATE',
      'event_changed',
      person: 'NEW.person_id',
      before: _eventJson('OLD'),
      after: _eventJson('NEW'),
      when:
          '${_openRow('NEW')} AND (OLD.type IS NOT NEW.type '
          'OR OLD.at IS NOT NEW.at OR OLD.notes IS NOT NEW.notes)',
      coalesce: true,
    ),
    _trigger(
      _eventTable,
      'DELETE',
      'event_removed',
      person: 'OLD.person_id',
      before: _eventJson('OLD'),
      when: _openRow('OLD'),
    ),
    _trigger(
      _locationTable,
      'INSERT',
      'place_added',
      person: 'NEW.person_id',
      after: 'NEW.place',
      when: _openRow('NEW'),
    ),
    _trigger(
      _locationTable,
      'DELETE',
      'place_removed',
      person: 'OLD.person_id',
      before: 'OLD.place',
      when: _openRow('OLD'),
    ),
    _trigger(
      _historyTable,
      'INSERT',
      'background_added',
      person: 'NEW.person_id',
      after: "json_object('category', NEW.category, 'title', NEW.title)",
      when: _openRow('NEW'),
    ),
    _trigger(
      _historyTable,
      'DELETE',
      'background_removed',
      person: 'OLD.person_id',
      before: "json_object('category', OLD.category, 'title', OLD.title)",
      when: _openRow('OLD'),
    ),
    _trigger(
      _relationshipTable,
      'INSERT',
      'link_added',
      person: 'NEW.person_id',
      after: "json_object('person', NEW.related_person_id, 'type', NEW.type)",
      when: _openRow('NEW'),
    ),
    _trigger(
      _relationshipTable,
      'DELETE',
      'link_removed',
      person: 'OLD.person_id',
      before: "json_object('person', OLD.related_person_id, 'type', OLD.type)",
      when: _openRow('OLD'),
    ),
  ];

  static Future<void> _installPersonChanges(Database db) =>
      db.transaction((txn) async {
        await txn.execute(
          'CREATE TABLE IF NOT EXISTS $_changeTable ('
          'seq INTEGER PRIMARY KEY AUTOINCREMENT, person_id TEXT NOT NULL, '
          'at INTEGER NOT NULL, kind TEXT NOT NULL, before TEXT, after TEXT)',
        );
        await txn.execute(
          'CREATE INDEX IF NOT EXISTS ${_changeTable}_person '
          'ON $_changeTable (person_id, seq)',
        );
        await txn.execute('CREATE TABLE IF NOT EXISTS $_muteTable (x INTEGER)');
        // A kill mid-merge must not leave the log switched off.
        await txn.delete(_muteTable);
        final existing = await txn.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'trigger' "
          "AND name LIKE 'pc\\_%' ESCAPE '\\'",
        );
        for (final row in existing) {
          await txn.execute('DROP TRIGGER IF EXISTS ${row['name']}');
        }
        for (final sql in _changeTriggers) {
          await txn.execute(sql);
        }
      });

  static const _stateTable = 'person_state';
  static const _purgedKey = 'private_log_purged_v1';

  /// What builds before the log's private rule wrote of namespaced rows,
  /// passcode tags included. Once.
  Future<void> _purgePrivateLog(Database db) async {
    try {
      await db.execute(
        'CREATE TABLE IF NOT EXISTS $_stateTable '
        '(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      final done = await db.query(
        _stateTable,
        where: 'key = ?',
        whereArgs: [_purgedKey],
      );
      if (done.isNotEmpty) return;
      for (final table in [_personTable, ..._sealedTables]) {
        await purgePrivateEntries(db, table, _privateRowSql);
      }
      await db.insert(_stateTable, {
        'key': _purgedKey,
        'value': '1',
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
    } catch (_) {
      // Tried again next launch.
    }
  }

  static const _groupsJoinedKey = 'same_name_groups_joined_v1';

  /// Profile imports before 2026-10-23 made a new group for every row, so
  /// one group of seventy was seventy groups of one. The open set's groups
  /// with one name and kind become the first of them. Once.
  Future<void> _joinSameNameGroups(Database db) async {
    try {
      final done = await db.query(
        _stateTable,
        where: 'key = ?',
        whereArgs: [_groupsJoinedKey],
      );
      if (done.isNotEmpty) return;
      const first =
          '(SELECT MIN(g.group_id) FROM $_groupTable g '
          "WHERE g.passcode_hash = '' AND lower(g.name) = lower($_groupTable.name) "
          'AND g.kind = $_groupTable.kind)';
      await db.transaction((txn) async {
        await txn.insert(_muteTable, {'x': 1});
        await txn.execute(
          'UPDATE OR IGNORE $_groupTable SET group_id = $first '
          "WHERE passcode_hash = '' AND name != ''",
        );
        // A person in two of the copies: the one left over goes.
        await txn.execute(
          'DELETE FROM $_groupTable '
          "WHERE passcode_hash = '' AND name != '' AND group_id != $first",
        );
        await txn.delete(_muteTable);
        await txn.insert(_stateTable, {
          'key': _groupsJoinedKey,
          'value': '1',
        }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
      });
    } catch (_) {
      // Tried again next launch.
    }
  }

  /// Every passcode tag a profile or a sealed set is kept under.
  Future<Set<String>> namespaces() async {
    final db = await _open();
    final out = <String>{};
    for (final table in [_personTable, ..._sealedTables]) {
      for (final row in await db.rawQuery(
        "SELECT DISTINCT passcode_hash AS t FROM $table "
        "WHERE COALESCE(passcode_hash, '') != ''",
      )) {
        out.add(row['t'] as String);
      }
    }
    return out;
  }

  /// Moves everything kept under [from] to [to]. A row whose key already
  /// exists under [to] stays where it is rather than replacing it.
  Future<void> retag(String from, String to) async {
    final db = await _open();
    await db.transaction((txn) async {
      for (final table in [_personTable, ..._sealedTables]) {
        await txn.rawUpdate(
          'UPDATE OR IGNORE $table SET passcode_hash = ? WHERE passcode_hash = ?',
          [to, from],
        );
      }
    });
  }

  /// A compact copy at [dest] without [hiddenIds]' memberships or avatars.
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
      'UPDATE $_personTable SET avatar_local_id = NULL, avatar_face = NULL '
          'WHERE avatar_local_id IN (SELECT id FROM drop_ids)',
      if (slim) changeLogTailScrub,
    ],
  );

  static const _createHistoryTableSql =
      '''
    CREATE TABLE $_historyTable (
      id TEXT PRIMARY KEY,
      person_id TEXT NOT NULL,
      category TEXT NOT NULL,
      title TEXT NOT NULL,
      start_date INTEGER,
      end_date INTEGER,
      notes TEXT NOT NULL DEFAULT '',
      custom_fields TEXT NOT NULL DEFAULT '[]',
      titles TEXT NOT NULL DEFAULT '[]',
      projects TEXT NOT NULL DEFAULT '[]',
      awards TEXT NOT NULL DEFAULT '[]',
      passcode_hash TEXT NOT NULL DEFAULT '',
      payload TEXT NOT NULL DEFAULT ''
    )
  ''';

  /// One row per (person, passcode). The payload is the whole
  /// [PersonDetail] as JSON — sealed for every passcode but the open one,
  /// which is the profile anybody holding the phone already sees.
  ///
  /// `sealed = 0` on a non-open row means a profile that was locked before
  /// this table existed: its details were moved here under the passcode
  /// hash they were locked with, and there was no way to encrypt them on
  /// the way, because a hash is not a passcode. The first time those digits
  /// are typed the row is re-written sealed. See [_moveDetailOutOfPersonRows].
  static const _createDetailTableSql =
      '''
    CREATE TABLE $_detailTable (
      person_id TEXT NOT NULL,
      passcode_hash TEXT NOT NULL,
      payload TEXT NOT NULL,
      sealed INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (person_id, passcode_hash)
    )
  ''';

  /// Rebuilds the relationship table with the passcode in its key.
  ///
  /// Two people can be colleagues in one set and nothing in another, so the
  /// pair alone cannot identify a row — with the old two-column key,
  /// writing a link under a passcode *replaced* the one in the open set,
  /// because the insert is a replace-on-conflict. SQLite cannot widen a
  /// primary key in place, hence the copy.
  static Future<void> _widenRelationshipKey(Database db) async {
    const staging = '${_relationshipTable}_wide';
    await db.execute('DROP TABLE IF EXISTS $staging');
    await db.execute('''
      CREATE TABLE $staging (
        person_id TEXT NOT NULL,
        related_person_id TEXT NOT NULL,
        type TEXT NOT NULL,
        organization TEXT,
        created_at INTEGER NOT NULL,
        passcode_hash TEXT NOT NULL DEFAULT '',
        payload TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (person_id, related_person_id, passcode_hash)
      )
    ''');
    await db.execute('''
      INSERT INTO $staging
        (person_id, related_person_id, type, organization, created_at,
         passcode_hash, payload)
      SELECT person_id, related_person_id, type, organization, created_at,
             passcode_hash, ''
      FROM $_relationshipTable
    ''');
    await db.execute('DROP TABLE $_relationshipTable');
    await db.execute('ALTER TABLE $staging RENAME TO $_relationshipTable');
  }

  /// Everything a profile records as having happened. Namespaced and sealed
  /// the same way the other three are.
  static const _createEventTableSql =
      '''
    CREATE TABLE $_eventTable (
      id TEXT PRIMARY KEY,
      person_id TEXT NOT NULL,
      passcode_hash TEXT NOT NULL DEFAULT '',
      payload TEXT NOT NULL DEFAULT '',
      at INTEGER,
      type TEXT NOT NULL DEFAULT '',
      tags TEXT NOT NULL DEFAULT '[]',
      notes TEXT NOT NULL DEFAULT ''
    )
  ''';

  /// Who is in which group. The group itself has no row of its own: a group
  /// *is* its members, so an empty one is nothing, and a name and a kind
  /// repeated across the rows that use it is cheaper than a second table to
  /// keep in step with this one.
  static const _createGroupTableSql =
      '''
    CREATE TABLE $_groupTable (
      person_id TEXT NOT NULL,
      group_id TEXT NOT NULL,
      passcode_hash TEXT NOT NULL DEFAULT '',
      payload TEXT NOT NULL DEFAULT '',
      name TEXT NOT NULL DEFAULT '',
      kind TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (person_id, group_id, passcode_hash)
    )
  ''';

  /// Moves bio, birth date, gender and custom fields off the person row and
  /// into the namespace they belong to.
  ///
  /// An unlocked profile's details are the open set. A locked profile's are
  /// its passcode's — anything else would publish, on upgrade, exactly what
  /// the lock was put there to hide. The person row keeps its columns; they
  /// simply stop being read. Dropping them would rewrite the table for no
  /// gain and cost the one thing a migration must not: a way back.
  static Future<void> _moveDetailOutOfPersonRows(Database db) async {
    final rows = await db.query(
      _personTable,
      columns: [
        'id',
        'bio',
        'birth_date',
        'gender',
        'custom_fields',
        'locked',
        'passcode_hash',
        'passcode_hint',
        'updated_at',
      ],
    );
    for (final row in rows) {
      final locked = (row['locked'] as int? ?? 0) != 0;
      final hash = row['passcode_hash'] as String?;
      final namespace = locked && hash != null && hash.isNotEmpty ? hash : '';
      final payload = {
        'bio': row['bio'] as String? ?? '',
        'birthDate': row['birth_date'],
        'gender': row['gender'],
        'customFields': jsonDecode((row['custom_fields'] as String?) ?? '[]'),
        'impression': const <String, Object?>{},
        'hint': row['passcode_hint'] as String? ?? '',
      };
      await db.insert(_detailTable, {
        'person_id': row['id'],
        'passcode_hash': namespace,
        'payload': jsonEncode(payload),
        'sealed': 0,
        'updated_at':
            row['updated_at'] ?? DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
    }
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Empties this database. The log goes last, after the deletes above
  /// have fired their triggers into it — see [AssetRecordStore.clearAll].
  Future<void> clearAll() async {
    final db = await _open();
    final batch = db.batch()
      ..delete(_memberTable)
      ..delete(_relationshipTable)
      ..delete(_locationTable)
      ..delete(_historyTable)
      ..delete(_personTable)
      ..delete(_knownTable)
      ..delete(changeLogTable);
    await batch.commit(noResult: true);
  }

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

  /// Creates a new person under a fresh id, unless [id] is given and one
  /// already exists at it — then that existing one is returned, so a
  /// caller holding a stable id can create-or-get idempotently.
  Future<Person> create({required String name, String? id}) async {
    if (id != null) {
      final existing = await getById(id);
      if (existing != null) return existing;
    }
    final db = await _open();
    final now = DateTime.now();
    final person = Person(
      id: id ?? _uuid.v4(),
      name: name,
      createdAt: now,
      updatedAt: now,
    );
    await db.insert(_personTable, _toRow(person));
    return person;
  }

  Future<void> update(Person person) async {
    final db = await _open();
    await db.update(
      _personTable,
      _toRow(person),
      where: 'id = ?',
      whereArgs: [person.id],
    );
  }

  /// The details kept for [personId] under [passcodeHash].
  ///
  /// [PersonDetail.empty] for a passcode nothing has been written under,
  /// for the wrong passcode, and for a passcode whose [keys] this phone
  /// cannot derive — three situations the caller is deliberately unable to
  /// tell apart, because telling them apart is the whole thing this avoids.
  ///
  /// [keys] is unused for the open set and required for every other, since
  /// nothing else can be read without them.
  Future<PersonDetail> detailFor(
    String personId, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
    final db = await _open();
    final rows = await db.query(
      _detailTable,
      where: 'person_id = ? AND passcode_hash = ?',
      whereArgs: [personId, passcodeHash],
      limit: 1,
    );
    if (rows.isEmpty) return PersonDetail.empty;
    final row = rows.single;
    final payload = row['payload'] as String? ?? '';
    final sealed = (row['sealed'] as int? ?? 0) != 0;

    if (passcodeHash == openNamespace) return _decodePlain(payload);
    if (keys == null) return PersonDetail.empty;
    if (!sealed) {
      // Locked before this table existed: moved here in the clear because a
      // hash is not a passcode. Now that the digits have been typed, it can
      // be put beyond reach — including in every backup written from here.
      final upgraded = _decodePlain(payload);
      await saveDetail(
        personId,
        upgraded,
        scope: PersonScope.sealed(passcodeHash, keys),
      );
      return upgraded;
    }
    return _seal.open(payload, keys) ?? PersonDetail.empty;
  }

  Future<void> saveDetail(
    String personId,
    PersonDetail detail, {
    required PersonScope scope,
  }) async {
    final PersonScope(:passcodeHash, :keys) = scope;
    if (passcodeHash != openNamespace && keys == null) return;
    final db = await _open();
    await db.insert(_detailTable, {
      'person_id': personId,
      'passcode_hash': passcodeHash,
      'payload': passcodeHash == openNamespace
          ? jsonEncode(detail.toJson())
          : _seal.seal(detail, keys!),
      'sealed': passcodeHash == openNamespace ? 0 : 1,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
  }

  static PersonDetail _decodePlain(String payload) {
    try {
      return PersonDetail.fromJson(
        (jsonDecode(payload) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return PersonDetail.empty;
    }
  }

  Future<Person?> getById(String id) async {
    final db = await _open();
    final rows = await db.query(
      _personTable,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.single);
  }

  Future<List<Person>> listAll() async {
    final db = await _open();
    final rows = await db.query(_personTable, orderBy: 'created_at ASC');
    return rows.map(_fromRow).toList();
  }

  /// Whether anything besides the name was written for [id], in any set —
  /// what decides that a person left nameless may be dropped.
  Future<bool> hasAnyRecord(String id) async {
    final db = await _open();
    Future<bool> any(String table, String where, List<Object> args) async =>
        (await db.query(
          table,
          columns: ['1'],
          where: where,
          whereArgs: args,
          limit: 1,
        )).isNotEmpty;
    for (final table in const [
      _memberTable,
      _locationTable,
      _historyTable,
      _eventTable,
      _groupTable,
    ]) {
      if (await any(table, 'person_id = ?', [id])) return true;
    }
    if (await any(
      _relationshipTable,
      'person_id = ? OR related_person_id = ?',
      [id, id],
    )) {
      return true;
    }
    if (await any(_detailTable, "person_id = ? AND passcode_hash != ''", [
      id,
    ])) {
      return true;
    }
    return !(await detailFor(id)).isEmpty;
  }

  /// Deletes the person, their photo tags, every relationship touching
  /// them, their location history, their education/job history and their
  /// details, sealed sets included. Tagged photos themselves are untouched
  /// — same "membership only" precedent as `AlbumStore.remove`.
  Future<void> remove(String id) async {
    final db = await _open();
    // One write: a kill part-way left memberships of nobody (05#24).
    await db.transaction((txn) async {
      for (final table in [
        _detailTable,
        _memberTable,
        _eventTable,
        _groupTable,
        _locationTable,
        _historyTable,
      ]) {
        await txn.delete(table, where: 'person_id = ?', whereArgs: [id]);
      }
      await txn.delete(
        _relationshipTable,
        where: 'person_id = ? OR related_person_id = ?',
        whereArgs: [id, id],
      );
      await txn.delete(_personTable, where: 'id = ?', whereArgs: [id]);
      await txn.delete(_aliasTable, where: 'person_id = ?', whereArgs: [id]);
      await txn.delete(_knownTable, where: 'person_id = ?', whereArgs: [id]);
      await txn.delete(_changeTable, where: 'person_id = ?', whereArgs: [id]);
    });
  }

  /// Last seen dates photos and chats used to write, from before Last seen
  /// was worked out on the fly: an open one with no notes or tags, dated
  /// to the millisecond like one of their photos or messages ([derived]).
  /// A date set by hand is a calendar day, which no capture time matches.
  /// Returns how many were removed.
  Future<int> dropDerivedLastSeen(
    Future<bool> Function(String personId, DateTime at) derived,
  ) async {
    final db = await _open();
    final rows = await db.query(
      _eventTable,
      columns: const ['id', 'person_id', 'at', 'tags', 'notes'],
      where: "passcode_hash = '' AND type = ? AND at IS NOT NULL",
      whereArgs: [PersonEventType.lastSeen.name],
    );
    var removed = 0;
    for (final row in rows) {
      if ((row['notes'] as String? ?? '').isNotEmpty) continue;
      if ((row['tags'] as String? ?? '[]') != '[]') continue;
      final at = DateTime.fromMillisecondsSinceEpoch(row['at']! as int);
      if (!await derived(row['person_id']! as String, at)) continue;
      await removeEvent(row['id']! as String, scope: PersonScope.open);
      removed++;
    }
    return removed;
  }

  /// Moves [personId]'s First met back to [at] when that's earlier.
  Future<void> markMet(String personId, DateTime at) =>
      _moveFixed(personId, PersonEventType.firstMet, at, at.isBefore);

  Future<void> _moveFixed(
    String personId,
    PersonEventType type,
    DateTime at,
    bool Function(DateTime was) beats,
  ) async {
    final events = await eventsFor(personId);
    final fixed = events.where((e) => e.type == type).firstOrNull;
    if (fixed?.at case final was? when !beats(was)) return;
    await saveEvent(
      PersonEvent(
        id: fixed?.id ?? newId(),
        personId: personId,
        type: type,
        at: at,
        tags: fixed?.tags ?? const [],
        notes: fixed?.notes ?? '',
      ),
      scope: PersonScope.open,
    );
  }

  /// One "imported" line per person, in one batch: chats and writings go
  /// to other databases, where no trigger here sees them. Each value is
  /// what came in — `source` (chats, words, jobs, profile, people) plus
  /// counts — kept as JSON in `after`.
  Future<void> logImports(Map<String, Map<String, Object?>> byPerson) async {
    if (byPerson.isEmpty) return;
    final db = await _open();
    final batch = db.batch();
    for (final MapEntry(:key, :value) in byPerson.entries) {
      batch.rawInsert(
        'INSERT INTO $_changeTable (person_id, at, kind, before, after) '
        "SELECT ?, $_nowMs, 'imported', NULL, ? "
        'WHERE NOT EXISTS (SELECT 1 FROM $_muteTable)',
        [key, jsonEncode(value)],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Remembers what imports called people, so the next one matches them
  /// without asking. Names equal to the person's own are left out; one
  /// already known is kept as it was. One batch.
  Future<void> rememberKnownAs(Iterable<KnownAs> known) async {
    final list = known.where((k) => k.key.isNotEmpty).toList();
    if (list.isEmpty) return;
    final db = await _open();
    final ids = {for (final k in list) k.personId}.toList();
    final names = {
      for (final r in await db.query(
        _personTable,
        columns: ['id', 'name'],
        where: 'id IN (${List.filled(ids.length, '?').join(',')})',
        whereArgs: ids,
      ))
        r['id'] as String: nameKey(r['name'] as String),
    };
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final k in list) {
      final own = names[k.personId];
      if (own == null) continue;
      if (k.kind == KnownAs.name && k.key == own) continue;
      batch.insert(_knownTable, {
        'person_id': k.personId,
        'kind': k.kind,
        'key': k.key,
        'value': k.value.trim(),
        'added_at': now,
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  /// Every remembered name and handle, oldest first.
  Future<List<KnownAs>> allKnownAs() async {
    final db = await _open();
    return [
      for (final r in await db.query(_knownTable, orderBy: 'added_at, rowid'))
        KnownAs(
          personId: r['person_id'] as String,
          kind: r['kind'] as String,
          value: r['value'] as String,
        ),
    ];
  }

  Future<List<KnownAs>> knownAsOf(String personId) async {
    final db = await _open();
    return [
      for (final r in await db.query(
        _knownTable,
        where: 'person_id = ?',
        whereArgs: [personId],
        orderBy: 'added_at, rowid',
      ))
        KnownAs(
          personId: personId,
          kind: r['kind'] as String,
          value: r['value'] as String,
        ),
    ];
  }

  Future<void> forgetKnownAs(KnownAs known) async {
    final db = await _open();
    await db.delete(
      _knownTable,
      where: 'person_id = ? AND kind = ? AND key = ?',
      whereArgs: [known.personId, known.kind, known.key],
    );
  }

  /// One read for an import: remembered names and handles, and the names
  /// people went by before a rename or merge.
  Future<KnownNames> knownNames(
    List<Person> people, {
    Map<String, Set<String>> handles = const {},
  }) async => KnownNames(
    people,
    known: await allKnownAs(),
    former: await allFormerNames(),
    handles: handles,
  );

  /// The `source` of each person's "imported" lines so far.
  Future<Map<String, Set<String>>> importedSources() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT person_id, after FROM $_changeTable '
      "WHERE kind = 'imported'",
    );
    final out = <String, Set<String>>{};
    for (final r in rows) {
      try {
        final source = (jsonDecode(r['after'] as String) as Map)['source'];
        if (source is String) {
          (out[r['person_id'] as String] ??= {}).add(source);
        }
      } catch (_) {
        // Unreadable: as if never logged.
      }
    }
    return out;
  }

  /// Open jobs that came from a work-history file — those carry its
  /// content ids (`job-…`, see `WorkHistoryFile`) — per person.
  Future<Map<String, int>> importedJobCounts() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT person_id, COUNT(*) AS n FROM $_historyTable '
      "WHERE passcode_hash = ? AND id LIKE 'job-%' GROUP BY person_id",
      [openNamespace],
    );
    return {for (final r in rows) r['person_id'] as String: r['n'] as int};
  }

  /// [personId]'s changes, newest first.
  Future<List<PersonChange>> changesOf(String personId) async {
    final db = await _open();
    final rows = await db.query(
      _changeTable,
      where: 'person_id = ?',
      whereArgs: [personId],
      orderBy: 'seq DESC',
    );
    return [
      for (final r in rows)
        PersonChange(
          at: DateTime.fromMillisecondsSinceEpoch(r['at'] as int),
          kind: r['kind'] as String,
          before: r['before'] as String?,
          after: r['after'] as String?,
        ),
    ];
  }

  /// Names each person has gone by: renamed from, or merged in. Oldest
  /// first, the current name left out.
  Future<Map<String, List<String>>> allFormerNames() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT c.person_id, c.before, p.name FROM $_changeTable c '
      'JOIN $_personTable p ON p.id = c.person_id '
      "WHERE c.kind IN ('name', 'merged') AND c.before IS NOT NULL "
      'ORDER BY c.seq',
    );
    final out = <String, List<String>>{};
    for (final r in rows) {
      final name = (r['before'] as String).trim();
      if (name.isEmpty || name == r['name']) continue;
      final list = out.putIfAbsent(r['person_id'] as String, () => []);
      if (!list.contains(name)) list.add(name);
    }
    return out;
  }

  Future<List<String>> formerNames(String personId) async =>
      (await allFormerNames())[personId] ?? const [];

  /// The ids merged into [personId], oldest first.
  Future<List<String>> aliasesOf(String personId) async {
    final db = await _open();
    final rows = await db.query(
      _aliasTable,
      columns: ['alias_id'],
      where: 'person_id = ?',
      whereArgs: [personId],
      orderBy: 'rowid',
    );
    return [for (final r in rows) r['alias_id'] as String];
  }

  /// Folds [goneId] into [keepId]: photos, groups, events, places,
  /// history, links to other people and every detail set move over, and
  /// [goneId] is removed. The open profile is combined field by field, the
  /// kept one winning where both have a value. One transaction.
  ///
  /// Refused, changing nothing, when both have a sealed set under the same
  /// code: those can only be combined with the code typed, and dropping
  /// either would lose what it holds.
  Future<PersonMergeOutcome> merge(String keepId, String goneId) async {
    if (keepId == goneId) return PersonMergeOutcome.missing;
    final db = await _open();
    final keep = await getById(keepId);
    final gone = await getById(goneId);
    if (keep == null || gone == null) return PersonMergeOutcome.missing;
    final details = await db.query(
      _detailTable,
      where: 'person_id IN (?, ?)',
      whereArgs: [keepId, goneId],
    );
    final keepHashes = {
      for (final r in details)
        if (r['person_id'] == keepId) r['passcode_hash'] as String,
    };
    for (final r in details) {
      final hash = r['passcode_hash'] as String;
      if (r['person_id'] == goneId &&
          hash != openNamespace &&
          keepHashes.contains(hash)) {
        return PersonMergeOutcome.sealedConflict;
      }
    }
    PersonDetail openOf(String id) {
      for (final r in details) {
        if (r['person_id'] == id && r['passcode_hash'] == openNamespace) {
          return _decodePlain(r['payload'] as String? ?? '');
        }
      }
      return PersonDetail.empty;
    }

    final combined = _combined(openOf(keepId), openOf(goneId));
    await db.transaction((txn) async {
      // Moving rows from one id to the other isn't a change to either.
      await txn.insert(_muteTable, {'x': 1});
      await txn.rawInsert(
        'INSERT OR IGNORE INTO $_memberTable '
        '(person_id, local_id, added_at, via_face) '
        'SELECT ?, local_id, added_at, via_face FROM $_memberTable '
        'WHERE person_id = ?',
        [keepId, goneId],
      );
      await txn.rawInsert(
        'INSERT OR IGNORE INTO $_groupTable '
        '(person_id, group_id, passcode_hash, payload, name, kind) '
        'SELECT ?, group_id, passcode_hash, payload, name, kind '
        'FROM $_groupTable WHERE person_id = ?',
        [keepId, goneId],
      );
      for (final table in [_eventTable, _locationTable, _historyTable]) {
        await txn.update(
          table,
          {'person_id': keepId},
          where: 'person_id = ?',
          whereArgs: [goneId],
        );
      }
      // Links: theirs become the kept one's, never a link to oneself.
      await txn.rawInsert(
        'INSERT OR IGNORE INTO $_relationshipTable '
        '(person_id, related_person_id, type, organization, created_at, '
        'passcode_hash, payload) '
        'SELECT ?, related_person_id, type, organization, created_at, '
        'passcode_hash, payload FROM $_relationshipTable '
        'WHERE person_id = ? AND related_person_id != ?',
        [keepId, goneId, keepId],
      );
      await txn.rawInsert(
        'INSERT OR IGNORE INTO $_relationshipTable '
        '(person_id, related_person_id, type, organization, created_at, '
        'passcode_hash, payload) '
        'SELECT person_id, ?, type, organization, created_at, '
        'passcode_hash, payload FROM $_relationshipTable '
        'WHERE related_person_id = ? AND person_id != ?',
        [keepId, goneId, keepId],
      );
      await txn.update(
        _detailTable,
        {'person_id': keepId},
        where: 'person_id = ? AND passcode_hash != ?',
        whereArgs: [goneId, openNamespace],
      );
      await txn.insert(_detailTable, {
        'person_id': keepId,
        'passcode_hash': openNamespace,
        'payload': jsonEncode(combined.toJson()),
        'sealed': 0,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
      for (final table in [_memberTable, _groupTable, _detailTable]) {
        await txn.delete(table, where: 'person_id = ?', whereArgs: [goneId]);
      }
      await txn.update(
        _aliasTable,
        {'person_id': keepId},
        where: 'person_id = ?',
        whereArgs: [goneId],
      );
      await txn.insert(_aliasTable, {
        'alias_id': goneId,
        'person_id': keepId,
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
      await txn.rawUpdate(
        'UPDATE OR IGNORE $_knownTable SET person_id = ? WHERE person_id = ?',
        [keepId, goneId],
      );
      await txn.delete(
        _knownTable,
        where: 'person_id = ?',
        whereArgs: [goneId],
      );
      await txn.delete(
        _relationshipTable,
        where: 'person_id = ? OR related_person_id = ?',
        whereArgs: [goneId, goneId],
      );
      if (keep.avatarLocalId == null && gone.avatarLocalId != null) {
        await txn.update(
          _personTable,
          {
            'avatar_local_id': gone.avatarLocalId,
            'avatar_face': gone.avatarFace?.encode(),
          },
          where: 'id = ?',
          whereArgs: [keepId],
        );
      }
      await txn.delete(_personTable, where: 'id = ?', whereArgs: [goneId]);
      await txn.delete(_muteTable);
      await txn.update(
        _changeTable,
        {'person_id': keepId},
        where: 'person_id = ?',
        whereArgs: [goneId],
      );
      await txn.rawInsert(
        'INSERT INTO $_changeTable (person_id, at, kind, before, after) '
        "VALUES (?, $_nowMs, 'merged', ?, ?)",
        [keepId, gone.name, keep.name],
      );
    });
    return PersonMergeOutcome.merged;
  }

  static PersonDetail _combined(PersonDetail keep, PersonDetail gone) {
    String key(PersonCustomField f) => '${f.label}\u0000${f.value}';
    final fields = {for (final f in keep.customFields) key(f)};
    final keepBio = keep.bio.trim(), goneBio = gone.bio.trim();
    return keep.copyWith(
      bio: keepBio.isEmpty || goneBio.isEmpty || keepBio.contains(goneBio)
          ? (keepBio.isEmpty ? gone.bio : keep.bio)
          : '${keep.bio}\n\n${gone.bio}',
      birthDate: () => keep.birthDate ?? gone.birthDate,
      gender: () => keep.gender ?? gone.gender,
      customFields: [
        ...keep.customFields,
        for (final f in gone.customFields)
          if (!fields.contains(key(f))) f,
      ],
      traits: {
        ...gone.traits,
        for (final MapEntry(:key, :value) in keep.traits.entries)
          if (value.trim().isNotEmpty) key: value,
      },
    );
  }

  // --- Photo membership ---

  /// [fillAvatar] false for photos that must never be anyone's picture —
  /// hidden ones.
  /// [viaFace]: linked because a face in it was named them, so naming the
  /// face otherwise unlinks it again ([removeFaceTags]). A link made any
  /// other way is the user's own and stays.
  Future<void> addAssets(
    String personId,
    Iterable<String> localIds, {
    bool fillAvatar = true,
    bool viaFace = false,
  }) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final localId in localIds) {
      batch.insert(_memberTable, {
        'person_id': personId,
        'local_id': localId,
        'added_at': now,
        'via_face': viaFace ? 1 : 0,
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
      // Added by hand to a photo a face had put here: it's theirs now.
      if (!viaFace) {
        batch.update(
          _memberTable,
          {'via_face': 0},
          where: 'person_id = ? AND local_id = ? AND via_face = 1',
          whereArgs: [personId, localId],
        );
      }
    }
    await batch.commit(noResult: true);

    // Somebody with no picture on them yet takes the first photo they're
    // tagged in. Every way of linking a photo to a person comes through
    // here, so this is the one place it needs saying — and it only ever
    // fills an empty slot, so a portrait chosen on purpose stays.
    final first = localIds.firstOrNull;
    if (first == null || !fillAvatar) return;
    final person = await getById(personId);
    if (person == null || person.avatarLocalId != null) return;
    await update(person.copyWith(avatarLocalId: first));
  }

  Future<void> removeAsset(String personId, String localId) =>
      removeAssets(personId, [localId]);

  /// Unlinks [localIds] from [personId] where a named face linked them;
  /// photos added by hand stay.
  Future<void> removeFaceTags(
    String personId,
    Iterable<String> localIds,
  ) async {
    final ids = localIds.toList();
    if (ids.isEmpty) return;
    final db = await _open();
    await db.delete(
      _memberTable,
      where:
          'person_id = ? AND via_face = 1 AND local_id IN '
          '(${List.filled(ids.length, '?').join(',')})',
      whereArgs: [personId, ...ids],
    );
  }

  Future<void> removeAssets(String personId, Iterable<String> localIds) async {
    final db = await _open();
    final ids = localIds.toList();
    final batch = db.batch();
    // Under SQLite's bound-parameter limit.
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      batch.delete(
        _memberTable,
        where:
            'person_id = ? AND local_id IN '
            '(${List.filled(chunk.length, '?').join(',')})',
        whereArgs: [personId, ...chunk],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Drops [localIds] from every person, and as an avatar — photos deleted
  /// for good. One batch, however many.
  Future<void> forgetAssets(Iterable<String> localIds) async {
    final db = await _open();
    final ids = localIds.toList();
    final batch = db.batch();
    // Under SQLite's bound-parameter limit.
    for (var i = 0; i < ids.length; i += 500) {
      final chunk = ids.sublist(i, i + 500 > ids.length ? ids.length : i + 500);
      final marks = List.filled(chunk.length, '?').join(',');
      batch
        ..delete(_memberTable, where: 'local_id IN ($marks)', whereArgs: chunk)
        ..update(
          _personTable,
          {'avatar_local_id': null, 'avatar_face': null},
          where: 'avatar_local_id IN ($marks)',
          whereArgs: chunk,
        );
    }
    await batch.commit(noResult: true);
  }

  /// Turns the avatar boxes taken from [localId] upright, as its face
  /// boxes just were (05#7). Names and photos are untouched.
  Future<void> reorientAvatars(String localId, int orientation) async {
    final db = await _open();
    final rows = await db.query(
      _personTable,
      columns: const ['id', 'avatar_face'],
      where: 'avatar_local_id = ? AND avatar_face IS NOT NULL',
      whereArgs: [localId],
    );
    final batch = db.batch();
    for (final row in rows) {
      final face = FaceRect.decode(row['avatar_face'] as String?);
      if (face == null) continue;
      batch.update(
        _personTable,
        {'avatar_face': face.oriented(orientation).encode()},
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<String>> localIdsIn(String personId) async {
    final db = await _open();
    final rows = await db.query(
      _memberTable,
      columns: ['local_id'],
      where: 'person_id = ?',
      whereArgs: [personId],
    );
    return rows.map((r) => r['local_id'] as String).toList();
  }

  /// Every person's photos in one query, by person id — for callers that
  /// would otherwise ask [localIdsIn] once per person.
  Future<Map<String, List<String>>> allMemberships() async {
    final db = await _open();
    final rows = await db.query(
      _memberTable,
      columns: ['person_id', 'local_id'],
    );
    final byPerson = <String, List<String>>{};
    for (final row in rows) {
      byPerson
          .putIfAbsent(row['person_id'] as String, () => [])
          .add(row['local_id'] as String);
    }
    return byPerson;
  }

  /// How many photos [personId] shares with each other person, in one query.
  Future<Map<String, int>> sharedPhotoCounts(String personId) async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT b.person_id AS id, COUNT(*) AS n FROM $_memberTable a '
      'JOIN $_memberTable b ON b.local_id = a.local_id '
      'WHERE a.person_id = ? AND b.person_id != ? GROUP BY b.person_id',
      [personId, personId],
    );
    return {for (final r in rows) r['id'] as String: r['n'] as int};
  }

  /// Reverse of [localIdsIn] — every [Person] tagged in one photo, for the
  /// detail screen's People section.
  Future<List<Person>> peopleFor(String localId) async {
    final db = await _open();
    final memberRows = await db.query(
      _memberTable,
      columns: ['person_id'],
      where: 'local_id = ?',
      whereArgs: [localId],
    );
    final personIds = memberRows.map((r) => r['person_id'] as String).toList();
    if (personIds.isEmpty) return [];
    final placeholders = List.filled(personIds.length, '?').join(', ');
    final rows = await db.query(
      _personTable,
      where: 'id IN ($placeholders)',
      whereArgs: personIds,
    );
    return rows.map(_fromRow).toList();
  }

  // --- Namespacing ---

  /// Splits a row into what a query may see and what only the passcode may.
  ///
  /// The open set keeps its columns exactly as it always has: it is the
  /// profile anybody holding the phone can read anyway, and keeping it
  /// queryable is what makes the autocomplete pickers instant. Every other
  /// set keeps only [structural] — whose row it is, and which passcode —
  /// and seals the rest, so the database file, and every backup taken from
  /// it, hold ciphertext.
  ///
  /// [blanks] are the placeholders the sealed row writes into the columns it
  /// is no longer using. They exist because those columns are `NOT NULL`,
  /// and they are constant, so they say nothing.
  Map<String, Object?> _rowFor({
    required Map<String, Object?> structural,
    required Map<String, Object?> content,
    required Map<String, Object?> blanks,
    required String passcodeHash,
    AlbumKeys? keys,
  }) => passcodeHash == openNamespace
      ? {...structural, ...content, 'payload': ''}
      : {...structural, ...blanks, 'payload': _seal.sealJson(content, keys!)};

  /// The row as its writer meant it, whichever way it was stored. `null` for
  /// a sealed row these keys do not open — which the caller drops, so an
  /// unreadable set and an empty one look the same.
  Map<String, Object?>? _contentOf(
    Map<String, Object?> row,
    String passcodeHash,
    AlbumKeys? keys,
  ) {
    if (passcodeHash == openNamespace) return row;
    if (keys == null) return null;
    final opened = _seal.openJson(row['payload'] as String? ?? '', keys);
    return opened == null ? null : {...row, ...opened};
  }

  /// True when a write to [passcodeHash] cannot be sealed and so must not
  /// happen — saving in the clear under a passcode is worse than not saving.
  static bool _unsealable(String passcodeHash, AlbumKeys? keys) =>
      passcodeHash != openNamespace && keys == null;

  // --- Relationships ---

  /// Links [personId] to [relatedPersonId] with [type] — stored both ways
  /// (mirrored, `type`'s inverse for `parent`/`child`) so either profile's
  /// relationship list, and the graph, see it without a second query.
  /// [organization] (company/school/org) is shared as-is by both directions
  /// — only meaningful when `relationshipNeedsOrganization(type)`.
  ///
  /// Both directions land in the same namespace: a link added while a
  /// passcode is open belongs to that passcode, and shows on the other
  /// profile only when the same digits are typed there.
  Future<void> addRelationship(
    String personId,
    String relatedPersonId,
    RelationshipType type, {
    String? organization,
    required PersonScope scope,
  }) async {
    final PersonScope(:passcodeHash, :keys) = scope;
    if (_unsealable(passcodeHash, keys)) return;
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final inverse = switch (type) {
      RelationshipType.parent => RelationshipType.child,
      RelationshipType.child => RelationshipType.parent,
      _ => type,
    };
    final batch = db.batch();
    for (final (from, to, kind) in [
      (personId, relatedPersonId, type),
      (relatedPersonId, personId, inverse),
    ]) {
      batch.insert(
        _relationshipTable,
        _rowFor(
          structural: {
            'person_id': from,
            'related_person_id': to,
            'passcode_hash': passcodeHash,
            'created_at': now,
          },
          content: {'type': kind.name, 'organization': organization},
          blanks: const {'type': '', 'organization': null},
          passcodeHash: passcodeHash,
          keys: keys,
        ),
        conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> removeRelationship(
    String personId,
    String relatedPersonId, {
    required PersonScope scope,
  }) async {
    final passcodeHash = scope.passcodeHash;
    final db = await _open();
    final batch = db.batch();
    for (final (a, b) in [
      (personId, relatedPersonId),
      (relatedPersonId, personId),
    ]) {
      batch.delete(
        _relationshipTable,
        where: 'person_id = ? AND related_person_id = ? AND passcode_hash = ?',
        whereArgs: [a, b, passcodeHash],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<PersonRelationship>> relationshipsFor(
    String personId, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
    final db = await _open();
    final rows = await db.query(
      _relationshipTable,
      where: 'person_id = ? AND passcode_hash = ?',
      whereArgs: [personId, passcodeHash],
    );
    return _relationships(rows, passcodeHash, keys);
  }

  /// Every relationship row in this namespace — powers the graph screen.
  Future<List<PersonRelationship>> allRelationships({
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
    final db = await _open();
    final rows = await db.query(
      _relationshipTable,
      where: 'passcode_hash = ?',
      whereArgs: [passcodeHash],
    );
    return _relationships(rows, passcodeHash, keys);
  }

  List<PersonRelationship> _relationships(
    List<Map<String, Object?>> rows,
    String passcodeHash,
    AlbumKeys? keys,
  ) => [
    for (final row in rows)
      if (_contentOf(row, passcodeHash, keys) case final content?)
        _relationshipFromRow(content),
  ];

  /// Every distinct organization used in this namespace — the searchable
  /// picker's "select if exists" list for colleague/schoolmate/other.
  Future<Set<String>> allOrganizations({
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
    if (passcodeHash == openNamespace) {
      final db = await _open();
      final rows = await db.query(
        _relationshipTable,
        columns: ['organization'],
        distinct: true,
        where:
            "organization IS NOT NULL AND organization != '' "
            "AND passcode_hash = ''",
      );
      return rows.map((r) => r['organization'] as String).toSet();
    }
    return {
      for (final r in await allRelationships(
        passcodeHash: passcodeHash,
        keys: keys,
      ))
        if (r.organization case final org?)
          if (org.isNotEmpty) org,
    };
  }

  // --- Location history ---

  /// Insert-or-replace by [PersonLocation.id] — also how an existing entry
  /// gets edited (pass its own `id` back with updated fields).
  Future<void> addLocation(
    PersonLocation location, {
    required PersonScope scope,
  }) async {
    final PersonScope(:passcodeHash, :keys) = scope;
    if (_unsealable(passcodeHash, keys)) return;
    final db = await _open();
    await db.insert(
      _locationTable,
      _rowFor(
        structural: {
          'id': location.id,
          'person_id': location.personId,
          'passcode_hash': passcodeHash,
        },
        content: {
          'kind': location.kind.name,
          'place': location.place,
          'since': location.since.millisecondsSinceEpoch,
        },
        blanks: const {'kind': '', 'place': '', 'since': 0},
        passcodeHash: passcodeHash,
        keys: keys,
      ),
      conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
    );
  }

  Future<void> removeLocation(String id, {required PersonScope scope}) async {
    final db = await _open();
    await db.delete(
      _locationTable,
      where: 'id = ? AND passcode_hash = ?',
      whereArgs: [id, scope.passcodeHash],
    );
  }

  Future<List<PersonLocation>> locationsFor(
    String personId, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
    final db = await _open();
    final rows = await db.query(
      _locationTable,
      where: 'person_id = ? AND passcode_hash = ?',
      whereArgs: [personId, passcodeHash],
    );
    // Sorted here rather than in SQL: a sealed row's `since` column is a
    // placeholder, and the real one only exists once it is opened.
    return [
      for (final row in rows)
        if (_contentOf(row, passcodeHash, keys) case final content?)
          _locationFromRow(content),
    ]..sort((a, b) => a.since.compareTo(b.since));
  }

  static PersonLocation _locationFromRow(Map<String, Object?> content) =>
      PersonLocation(
        id: content['id'] as String,
        personId: content['person_id'] as String,
        kind: LocationKind.values.byName(content['kind'] as String),
        place: content['place'] as String,
        since: DateTime.fromMillisecondsSinceEpoch(content['since'] as int),
      );

  /// Everyone's open set plus their sealed rows, for the app-data export:
  /// one query per table instead of a dozen per person.
  Future<Map<String, PersonExportSet>> exportSets() async {
    final db = await _open();
    final sets = <String, PersonExportSet>{};
    PersonExportSet of(Object? id) =>
        sets.putIfAbsent(id as String, PersonExportSet.new);
    const open = 'passcode_hash = ?';
    const openArgs = [openNamespace];

    for (final row in await db.query(
      _detailTable,
      where: open,
      whereArgs: openArgs,
    )) {
      of(row['person_id']).detail = _decodePlain(
        row['payload'] as String? ?? '',
      );
    }
    for (final row in await db.query(
      _historyTable,
      where: open,
      whereArgs: openArgs,
    )) {
      of(row['person_id']).history.add(_historyFromRow(row));
    }
    for (final row in await db.query(
      _locationTable,
      where: open,
      whereArgs: openArgs,
    )) {
      of(row['person_id']).locations.add(_locationFromRow(row));
    }
    for (final row in await db.query(
      _relationshipTable,
      where: open,
      whereArgs: openArgs,
    )) {
      of(row['person_id']).relationships.add(_relationshipFromRow(row));
    }
    for (final table in _sealedTables) {
      for (final row in await db.query(table, where: "passcode_hash != ''")) {
        of(row['person_id']).sealed.add({'table': table, ...row});
      }
    }
    for (final set in sets.values) {
      set.history.sort((a, b) {
        final byCategory = a.category.index.compareTo(b.category.index);
        if (byCategory != 0) return byCategory;
        return (a.startDate ?? DateTime(0)).compareTo(
          b.startDate ?? DateTime(0),
        );
      });
      set.locations.sort((a, b) => a.since.compareTo(b.since));
    }
    return sets;
  }

  static const _sealedTables = [
    _detailTable,
    _relationshipTable,
    _locationTable,
    _historyTable,
    _eventTable,
    _groupTable,
  ];

  // --- Education/job history ---

  /// Insert-or-replace by [PersonHistoryEntry.id] — also how an existing
  /// entry gets edited (pass its own `id` back with updated fields).
  Future<void> addHistoryEntry(
    PersonHistoryEntry entry, {
    required PersonScope scope,
  }) async {
    final PersonScope(:passcodeHash, :keys) = scope;
    if (_unsealable(passcodeHash, keys)) return;
    final db = await _open();
    await db.insert(
      _historyTable,
      _rowFor(
        structural: {
          'id': entry.id,
          'person_id': entry.personId,
          'passcode_hash': passcodeHash,
        },
        content: {
          'category': entry.category.name,
          'title': entry.title,
          'start_date': entry.startDate?.millisecondsSinceEpoch,
          'end_date': entry.endDate?.millisecondsSinceEpoch,
          'notes': entry.notes,
          'custom_fields': jsonEncode(
            entry.customFields.map((f) => f.toJson()).toList(),
          ),
          'titles': jsonEncode(entry.titles.map((t) => t.toJson()).toList()),
          'projects': jsonEncode(
            entry.projects.map((p) => p.toJson()).toList(),
          ),
          'awards': jsonEncode(entry.awards.map((a) => a.toJson()).toList()),
        },
        blanks: const {'category': '', 'title': ''},
        passcodeHash: passcodeHash,
        keys: keys,
      ),
      conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
    );
  }

  Future<void> removeHistoryEntry(
    String id, {
    required PersonScope scope,
  }) async {
    final db = await _open();
    await db.delete(
      _historyTable,
      where: 'id = ? AND passcode_hash = ?',
      whereArgs: [id, scope.passcodeHash],
    );
  }

  Future<List<PersonHistoryEntry>> historyFor(
    String personId,
    HistoryCategory category, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
    final db = await _open();
    final rows = await db.query(
      _historyTable,
      where: 'person_id = ? AND passcode_hash = ?',
      whereArgs: [personId, passcodeHash],
    );
    // Category and date are sealed with everything else, so both the filter
    // and the order happen once the row is open.
    return [
      for (final row in rows)
        if (_contentOf(row, passcodeHash, keys) case final content?)
          if (content['category'] == category.name) _historyFromRow(content),
      // Undated first, as `ORDER BY start_date ASC` did.
    ]..sort(
      (a, b) =>
          (a.startDate ?? DateTime(0)).compareTo(b.startDate ?? DateTime(0)),
    );
  }

  /// Every distinct title already used for [category] in this namespace —
  /// the searchable picker's "select if exists" list.
  Future<Set<String>> allHistoryTitles(
    HistoryCategory category, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
    if (passcodeHash == openNamespace) {
      final db = await _open();
      final rows = await db.query(
        _historyTable,
        columns: ['title'],
        distinct: true,
        where: "category = ? AND title != '' AND passcode_hash = ''",
        whereArgs: [category.name],
      );
      return rows.map((r) => r['title'] as String).toSet();
    }
    final db = await _open();
    final rows = await db.query(
      _historyTable,
      where: 'passcode_hash = ?',
      whereArgs: [passcodeHash],
    );
    return {
      for (final row in rows)
        if (_contentOf(row, passcodeHash, keys) case final content?)
          if (content['category'] == category.name)
            if ((content['title'] as String? ?? '').isNotEmpty)
              content['title'] as String,
    };
  }

  static PersonHistoryEntry _historyFromRow(Map<String, Object?> row) {
    final startMillis = row['start_date'] as int?;
    final endMillis = row['end_date'] as int?;
    final customFieldsJson =
        jsonDecode(row['custom_fields'] as String? ?? '[]') as List<dynamic>;
    final titlesJson =
        jsonDecode(row['titles'] as String? ?? '[]') as List<dynamic>;
    final projectsJson =
        jsonDecode(row['projects'] as String? ?? '[]') as List<dynamic>;
    final awardsJson =
        jsonDecode(row['awards'] as String? ?? '[]') as List<dynamic>;
    return PersonHistoryEntry(
      id: row['id'] as String,
      personId: row['person_id'] as String,
      category: HistoryCategory.values.byName(row['category'] as String),
      title: row['title'] as String,
      startDate: startMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(startMillis),
      endDate: endMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(endMillis),
      notes: row['notes'] as String? ?? '',
      customFields: customFieldsJson
          .map((f) => PersonCustomField.fromJson(f as Map<String, Object?>))
          .toList(),
      titles: titlesJson
          .map((t) => TimelineEntry.fromJson(t as Map<String, Object?>))
          .toList(),
      projects: projectsJson
          .map((p) => CareerProject.fromJson(p as Map<String, Object?>))
          .toList(),
      awards: awardsJson
          .map((a) => TimelineEntry.fromJson(a as Map<String, Object?>))
          .toList(),
    );
  }

  /// Every person's open-set details at once, by person id.
  ///
  /// The People page needs one field — gender — across everybody, and asking
  /// per person is a query per row. Only the open set: a list of faces anybody
  /// can see must not sort itself by something only a passcode opens.
  Future<Map<String, PersonDetail>> openDetails() async {
    final db = await _open();
    final rows = await db.query(_detailTable, where: "passcode_hash = ''");
    return {
      for (final row in rows)
        row['person_id'] as String: _decodePlain(
          row['payload'] as String? ?? '',
        ),
    };
  }

  // --- Groups ---

  Future<void> joinGroup(
    String personId,
    PersonGroup group, {
    required PersonScope scope,
  }) async {
    final PersonScope(:passcodeHash, :keys) = scope;
    if (_unsealable(passcodeHash, keys)) return;
    final db = await _open();
    await db.insert(
      _groupTable,
      _rowFor(
        structural: {
          'person_id': personId,
          'group_id': group.id,
          'passcode_hash': passcodeHash,
        },
        content: {'name': group.name, 'kind': group.kind.name},
        blanks: const {'name': '', 'kind': ''},
        passcodeHash: passcodeHash,
        keys: keys,
      ),
      conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
    );
  }

  /// Renames, or re-kinds, the open set's group for everyone in it.
  Future<void> updateGroup(
    String groupId, {
    String? name,
    GroupKind? kind,
  }) async {
    if (name == null && kind == null) return;
    final db = await _open();
    await db.update(
      _groupTable,
      {'name': ?name, 'kind': ?kind?.name},
      where: 'group_id = ? AND passcode_hash = ?',
      whereArgs: [groupId, openNamespace],
    );
  }

  /// The group gone from everyone in [scope]'s set; the people stay.
  Future<void> deleteGroup(String groupId, {required PersonScope scope}) async {
    final db = await _open();
    await db.delete(
      _groupTable,
      where: 'group_id = ? AND passcode_hash = ?',
      whereArgs: [groupId, scope.passcodeHash],
    );
  }

  Future<void> leaveGroup(
    String personId,
    String groupId, {
    required PersonScope scope,
  }) async {
    final db = await _open();
    await db.delete(
      _groupTable,
      where: 'person_id = ? AND group_id = ? AND passcode_hash = ?',
      whereArgs: [personId, groupId, scope.passcodeHash],
    );
  }

  Future<List<PersonGroup>> groupsFor(
    String personId, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
    final db = await _open();
    return _groups(
      await db.query(
        _groupTable,
        where: 'person_id = ? AND passcode_hash = ?',
        whereArgs: [personId, passcodeHash],
      ),
      passcodeHash,
      keys,
    );
  }

  /// Every group in this namespace, once each, with who is in it.
  Future<Map<PersonGroup, List<String>>> allGroups({
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
    final db = await _open();
    final rows = await db.query(
      _groupTable,
      where: 'passcode_hash = ?',
      whereArgs: [passcodeHash],
    );
    final byId = <String, PersonGroup>{};
    final members = <String, List<String>>{};
    for (final row in rows) {
      final content = _contentOf(row, passcodeHash, keys);
      if (content == null) continue;
      final id = content['group_id'] as String;
      byId[id] ??= PersonGroup(
        id: id,
        name: content['name'] as String? ?? '',
        kind:
            GroupKind.values
                .where((k) => k.name == content['kind'] as String?)
                .firstOrNull ??
            GroupKind.circle,
      );
      (members[id] ??= []).add(content['person_id'] as String);
    }
    return {
      for (final entry in byId.entries) entry.value: members[entry.key] ?? [],
    };
  }

  List<PersonGroup> _groups(
    List<Map<String, Object?>> rows,
    String passcodeHash,
    AlbumKeys? keys,
  ) => [
    for (final row in rows)
      if (_contentOf(row, passcodeHash, keys) case final content?)
        PersonGroup(
          id: content['group_id'] as String,
          name: content['name'] as String? ?? '',
          kind:
              GroupKind.values
                  .where((k) => k.name == content['kind'] as String?)
                  .firstOrNull ??
              GroupKind.circle,
        ),
  ];

  // --- Events ---

  /// Insert-or-replace by [PersonEvent.id].
  Future<void> saveEvent(
    PersonEvent event, {
    required PersonScope scope,
  }) async {
    final PersonScope(:passcodeHash, :keys) = scope;
    if (_unsealable(passcodeHash, keys)) return;
    final db = await _open();
    await db.insert(
      _eventTable,
      _rowFor(
        structural: {
          'id': event.id,
          'person_id': event.personId,
          'passcode_hash': passcodeHash,
        },
        content: {
          'type': event.type.name,
          'at': event.at?.millisecondsSinceEpoch,
          'tags': jsonEncode(event.tags),
          'notes': event.notes,
        },
        blanks: const {'type': '', 'at': null, 'tags': '[]', 'notes': ''},
        passcodeHash: passcodeHash,
        keys: keys,
      ),
      conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
    );
  }

  Future<void> removeEvent(String id, {required PersonScope scope}) async {
    final db = await _open();
    await db.delete(
      _eventTable,
      where: 'id = ? AND passcode_hash = ?',
      whereArgs: [id, scope.passcodeHash],
    );
  }

  /// Oldest first. Sorted here rather than in SQL, because a sealed row's
  /// date is a placeholder until it is opened.
  Future<List<PersonEvent>> eventsFor(
    String personId, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
    final db = await _open();
    final rows = await db.query(
      _eventTable,
      where: 'person_id = ? AND passcode_hash = ?',
      whereArgs: [personId, passcodeHash],
    );
    return [
      for (final row in rows)
        if (_contentOf(row, passcodeHash, keys) case final content?)
          PersonEvent.fromJson(
            content['id'] as String,
            content['person_id'] as String,
            {
              'type': content['type'],
              'at': content['at'],
              'tags': jsonDecode(content['tags'] as String? ?? '[]'),
              'notes': content['notes'],
            },
          ),
    ]..sort((a, b) => (a.at ?? DateTime(0)).compareTo(b.at ?? DateTime(0)));
  }

  /// Per person, from the open set in one query: the First met and Last
  /// seen rows, and the earliest and latest dated event of any kind — what
  /// People sorts by.
  Future<Map<String, PersonSpan>> openEventSpans() async {
    final db = await _open();
    final rows = await db.rawQuery(
      'SELECT person_id, type, MIN(at) AS lo, MAX(at) AS hi FROM $_eventTable '
      "WHERE passcode_hash = '' AND at IS NOT NULL GROUP BY person_id, type",
    );
    final out = <String, PersonSpan>{};
    DateTime at(Object? ms) => DateTime.fromMillisecondsSinceEpoch(ms! as int);
    for (final row in rows) {
      final id = row['person_id']! as String;
      final span = out[id] ?? const PersonSpan();
      out[id] = span.including(
        type: row['type'] as String?,
        lo: at(row['lo']),
        hi: at(row['hi']),
      );
    }
    return out;
  }

  /// Every row this person keeps behind a passcode, exactly as stored.
  ///
  /// Sealed, so this is ciphertext — which is what makes it safe to put in a
  /// backup that lands in iCloud Drive. The open set is not here: it rides
  /// in the snapshot's own typed fields, where builds older than this one
  /// can still read it.
  ///
  /// Rows rather than objects, deliberately. Nothing on this phone can open
  /// another passphrase's sets, and a backup that could only carry what this
  /// phone happens to be able to read would quietly drop them.
  Future<List<Map<String, Object?>>> sealedRowsFor(String personId) async {
    final db = await _open();
    final out = <Map<String, Object?>>[];
    for (final table in const [
      _detailTable,
      _relationshipTable,
      _locationTable,
      _historyTable,
      _eventTable,
      _groupTable,
    ]) {
      final rows = await db.query(
        table,
        where: "person_id = ? AND passcode_hash != ''",
        whereArgs: [personId],
      );
      for (final row in rows) {
        out.add({'table': table, ...row});
      }
    }
    return out;
  }

  /// Puts them back. Unknown tables and columns are skipped rather than
  /// thrown on: a snapshot written by a later build must not fail a restore.
  Future<void> restoreSealedRows(List<Map<String, Object?>> rows) async {
    final db = await _open();
    const known = {
      _detailTable,
      _relationshipTable,
      _locationTable,
      _historyTable,
      _eventTable,
      _groupTable,
    };
    final batch = db.batch();
    for (final row in rows) {
      final table = row['table'] as String?;
      if (table == null || !known.contains(table)) continue;
      batch.insert(
        table,
        {...row}..remove('table'),
        conflictAlgorithm: sqflite.ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  String newId() => _uuid.v4();

  static Map<String, Object?> _toRow(Person person) => {
    'id': person.id,
    'name': person.name,
    'avatar_local_id': person.avatarLocalId,
    'avatar_face': person.avatarFace?.encode(),
    'bio': person.bio,
    'birth_date': person.birthDate?.millisecondsSinceEpoch,
    'gender': person.gender?.name,
    'custom_fields': jsonEncode(
      person.customFields.map((f) => f.toJson()).toList(),
    ),
    'locked': person.locked ? 1 : 0,
    'passcode_hash': person.passcodeHash,
    'passcode_hint': person.passcodeHint,
    'first_name': person.firstName,
    'middle_name': person.middleName,
    'last_name': person.lastName,
    'created_at': person.createdAt.millisecondsSinceEpoch,
    'updated_at': person.updatedAt.millisecondsSinceEpoch,
  };

  static Person _fromRow(Map<String, Object?> row) {
    final birthMillis = row['birth_date'] as int?;
    final genderName = row['gender'] as String?;
    final customFieldsJson =
        jsonDecode(row['custom_fields'] as String? ?? '[]') as List<dynamic>;
    return Person(
      id: row['id'] as String,
      name: row['name'] as String,
      avatarLocalId: row['avatar_local_id'] as String?,
      avatarFace: FaceRect.decode(row['avatar_face'] as String?),
      bio: row['bio'] as String? ?? '',
      birthDate: birthMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(birthMillis),
      gender: genderName == null ? null : Gender.values.byName(genderName),
      customFields: customFieldsJson
          .map((f) => PersonCustomField.fromJson(f as Map<String, Object?>))
          .toList(),
      locked: (row['locked'] as int? ?? 0) != 0,
      passcodeHash: row['passcode_hash'] as String?,
      passcodeHint: row['passcode_hint'] as String?,
      firstName: row['first_name'] as String? ?? '',
      middleName: row['middle_name'] as String? ?? '',
      lastName: row['last_name'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    );
  }

  static PersonRelationship _relationshipFromRow(Map<String, Object?> row) =>
      PersonRelationship(
        personId: row['person_id'] as String,
        relatedPersonId: row['related_person_id'] as String,
        type: RelationshipType.values.byName(row['type'] as String),
        organization: row['organization'] as String?,
      );
}

/// One person's slice of [PersonStore.exportSets].
class PersonExportSet {
  PersonDetail detail = PersonDetail.empty;
  final history = <PersonHistoryEntry>[];
  final locations = <PersonLocation>[];
  final relationships = <PersonRelationship>[];
  final sealed = <Map<String, Object?>>[];
}

/// What [PersonStore.openEventSpans] knows of one person's dates.
class PersonSpan {
  const PersonSpan({this.firstMet, this.lastSeen, this.earliest, this.latest});

  final DateTime? firstMet;
  final DateTime? lastSeen;
  final DateTime? earliest;
  final DateTime? latest;

  PersonSpan including({
    required String? type,
    required DateTime lo,
    required DateTime hi,
  }) => PersonSpan(
    firstMet: type == PersonEventType.firstMet.name ? lo : firstMet,
    lastSeen: type == PersonEventType.lastSeen.name ? hi : lastSeen,
    earliest: earliest == null || lo.isBefore(earliest!) ? lo : earliest,
    latest: latest == null || hi.isAfter(latest!) ? hi : latest,
  );
}

enum PersonMergeOutcome { merged, sealedConflict, missing }

/// One entry in a person's change log. [before] and [after] are the old
/// and new value: text for a name, place or group, a JSON object for
/// details, events, background and links, a photo's id for photos.
class PersonChange {
  const PersonChange({
    required this.at,
    required this.kind,
    this.before,
    this.after,
  });

  final DateTime at;
  final String kind;
  final String? before;
  final String? after;
}

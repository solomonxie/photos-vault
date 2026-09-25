import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show Database, DatabaseFactory, OpenDatabaseOptions;
import 'package:uuid/uuid.dart';

import '../backup/change_log.dart';
import '../vault/keys.dart' show AlbumKeys;
import 'person.dart';
import 'person_detail.dart';

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

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path =
        _path ?? p.join(await _databaseFactory.getDatabasesPath(), 'people.db');
    final db = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 7,
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
        },
      ),
    );
    // After the migrations, never inside them: a trigger has to describe
    // the schema the app just finished upgrading to.
    await installChangeLog(db, const [
      _personTable,
      _memberTable,
      _relationshipTable,
      _locationTable,
      _historyTable,
      _detailTable,
    ]);
    _db = db;
    return db;
  }

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
      ..delete(changeLogTable);
    await batch.commit(noResult: true);
  }

  /// This store's database file, with the write-ahead log folded back in
  /// first — a copy taken without the checkpoint is missing the newest
  /// writes, which are still sitting in the `-wal` sidecar.
  ///
  /// `null` for an in-memory database, which has no file to copy.
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

  /// How far this database's change log has got. See `change_log.dart`.
  Future<int> changeMark() async => changeLogMark(await _open());

  /// The tail of this database's change log, for the copy in the backup.
  Future<List<Map<String, Object?>>> changeLogRows() async =>
      changeLogTail(await _open());

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
        passcodeHash: passcodeHash,
        keys: keys,
      );
      return upgraded;
    }
    return _seal.open(payload, keys) ?? PersonDetail.empty;
  }

  Future<void> saveDetail(
    String personId,
    PersonDetail detail, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
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

  /// Deletes the person, their photo tags, every relationship touching
  /// them, their location history, and their education/job history.
  /// Tagged photos themselves are untouched — same "membership only"
  /// precedent as `AlbumStore.remove`.
  Future<void> remove(String id) async {
    final db = await _open();
    await db.delete(_memberTable, where: 'person_id = ?', whereArgs: [id]);
    await db.delete(
      _relationshipTable,
      where: 'person_id = ? OR related_person_id = ?',
      whereArgs: [id, id],
    );
    await db.delete(_locationTable, where: 'person_id = ?', whereArgs: [id]);
    await db.delete(_historyTable, where: 'person_id = ?', whereArgs: [id]);
    await db.delete(_personTable, where: 'id = ?', whereArgs: [id]);
  }

  // --- Photo membership ---

  Future<void> addAssets(String personId, Iterable<String> localIds) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final localId in localIds) {
      batch.insert(_memberTable, {
        'person_id': personId,
        'local_id': localId,
        'added_at': now,
      }, conflictAlgorithm: sqflite.ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);

    // Somebody with no picture on them yet takes the first photo they're
    // tagged in. Every way of linking a photo to a person comes through
    // here, so this is the one place it needs saying — and it only ever
    // fills an empty slot, so a portrait chosen on purpose stays.
    final first = localIds.firstOrNull;
    if (first == null) return;
    final person = await getById(personId);
    if (person == null || person.avatarLocalId != null) return;
    await update(person.copyWith(avatarLocalId: first));
  }

  Future<void> removeAsset(String personId, String localId) async {
    final db = await _open();
    await db.delete(
      _memberTable,
      where: 'person_id = ? AND local_id = ?',
      whereArgs: [personId, localId],
    );
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
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
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
    String passcodeHash = openNamespace,
  }) async {
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
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
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

  Future<void> removeLocation(String id) async {
    final db = await _open();
    await db.delete(_locationTable, where: 'id = ?', whereArgs: [id]);
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
          PersonLocation(
            id: content['id'] as String,
            personId: content['person_id'] as String,
            kind: LocationKind.values.byName(content['kind'] as String),
            place: content['place'] as String,
            since: DateTime.fromMillisecondsSinceEpoch(content['since'] as int),
          ),
    ]..sort((a, b) => a.since.compareTo(b.since));
  }

  // --- Education/job history ---

  /// Insert-or-replace by [PersonHistoryEntry.id] — also how an existing
  /// entry gets edited (pass its own `id` back with updated fields).
  Future<void> addHistoryEntry(
    PersonHistoryEntry entry, {
    String passcodeHash = openNamespace,
    AlbumKeys? keys,
  }) async {
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

  Future<void> removeHistoryEntry(String id) async {
    final db = await _open();
    await db.delete(_historyTable, where: 'id = ?', whereArgs: [id]);
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

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart'
    show Database, DatabaseFactory, OpenDatabaseOptions;
import 'package:uuid/uuid.dart';

import '../backup/change_log.dart';
import 'person.dart';

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

  Database? _db;

  static const _personTable = 'person';
  static const _memberTable = 'person_asset';
  static const _relationshipTable = 'person_relationship';
  static const _locationTable = 'person_location';
  static const _historyTable = 'person_history';

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path =
        _path ?? p.join(await _databaseFactory.getDatabasesPath(), 'people.db');
    final db = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 5,
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
              PRIMARY KEY (person_id, related_person_id)
            )
          ''');
          await db.execute('''
            CREATE TABLE $_locationTable (
              id TEXT PRIMARY KEY,
              person_id TEXT NOT NULL,
              kind TEXT NOT NULL,
              place TEXT NOT NULL,
              since INTEGER NOT NULL
            )
          ''');
          await db.execute(_createHistoryTableSql);
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
      awards TEXT NOT NULL DEFAULT '[]'
    )
  ''';

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<void> clearAll() async {
    final db = await _open();
    final batch = db.batch()
      ..delete(_memberTable)
      ..delete(_relationshipTable)
      ..delete(_locationTable)
      ..delete(_historyTable)
      ..delete(_personTable);
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

  // --- Relationships ---

  /// Links [personId] to [relatedPersonId] with [type] — stored both ways
  /// (mirrored, `type`'s inverse for `parent`/`child`) so either profile's
  /// relationship list, and the graph, see it without a second query.
  /// [organization] (company/school/org) is shared as-is by both directions
  /// — only meaningful when `relationshipNeedsOrganization(type)`.
  Future<void> addRelationship(
    String personId,
    String relatedPersonId,
    RelationshipType type, {
    String? organization,
  }) async {
    final db = await _open();
    final now = DateTime.now().millisecondsSinceEpoch;
    final inverse = switch (type) {
      RelationshipType.parent => RelationshipType.child,
      RelationshipType.child => RelationshipType.parent,
      _ => type,
    };
    final batch = db.batch();
    batch.insert(_relationshipTable, {
      'person_id': personId,
      'related_person_id': relatedPersonId,
      'type': type.name,
      'organization': organization,
      'created_at': now,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
    batch.insert(_relationshipTable, {
      'person_id': relatedPersonId,
      'related_person_id': personId,
      'type': inverse.name,
      'organization': organization,
      'created_at': now,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
  }

  Future<void> removeRelationship(
    String personId,
    String relatedPersonId,
  ) async {
    final db = await _open();
    final batch = db.batch();
    batch.delete(
      _relationshipTable,
      where: 'person_id = ? AND related_person_id = ?',
      whereArgs: [personId, relatedPersonId],
    );
    batch.delete(
      _relationshipTable,
      where: 'person_id = ? AND related_person_id = ?',
      whereArgs: [relatedPersonId, personId],
    );
    await batch.commit(noResult: true);
  }

  Future<List<PersonRelationship>> relationshipsFor(String personId) async {
    final db = await _open();
    final rows = await db.query(
      _relationshipTable,
      where: 'person_id = ?',
      whereArgs: [personId],
    );
    return rows.map(_relationshipFromRow).toList();
  }

  /// Every relationship row across all people — powers the graph screen.
  Future<List<PersonRelationship>> allRelationships() async {
    final db = await _open();
    final rows = await db.query(_relationshipTable);
    return rows.map(_relationshipFromRow).toList();
  }

  /// Every distinct organization used so far — the searchable-picker's
  /// "select if exists" list for colleague/schoolmate/other relationships.
  Future<Set<String>> allOrganizations() async {
    final db = await _open();
    final rows = await db.query(
      _relationshipTable,
      columns: ['organization'],
      distinct: true,
      where: "organization IS NOT NULL AND organization != ''",
    );
    return rows.map((r) => r['organization'] as String).toSet();
  }

  // --- Location history ---

  /// Insert-or-replace by [PersonLocation.id] — also how an existing entry
  /// gets edited (pass its own `id` back with updated fields).
  Future<void> addLocation(PersonLocation location) async {
    final db = await _open();
    await db.insert(_locationTable, {
      'id': location.id,
      'person_id': location.personId,
      'kind': location.kind.name,
      'place': location.place,
      'since': location.since.millisecondsSinceEpoch,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
  }

  Future<void> removeLocation(String id) async {
    final db = await _open();
    await db.delete(_locationTable, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<PersonLocation>> locationsFor(String personId) async {
    final db = await _open();
    final rows = await db.query(
      _locationTable,
      where: 'person_id = ?',
      whereArgs: [personId],
      orderBy: 'since ASC',
    );
    return rows
        .map(
          (r) => PersonLocation(
            id: r['id'] as String,
            personId: r['person_id'] as String,
            kind: LocationKind.values.byName(r['kind'] as String),
            place: r['place'] as String,
            since: DateTime.fromMillisecondsSinceEpoch(r['since'] as int),
          ),
        )
        .toList();
  }

  // --- Education/job history ---

  /// Insert-or-replace by [PersonHistoryEntry.id] — also how an existing
  /// entry gets edited (pass its own `id` back with updated fields).
  Future<void> addHistoryEntry(PersonHistoryEntry entry) async {
    final db = await _open();
    await db.insert(_historyTable, {
      'id': entry.id,
      'person_id': entry.personId,
      'category': entry.category.name,
      'title': entry.title,
      'start_date': entry.startDate?.millisecondsSinceEpoch,
      'end_date': entry.endDate?.millisecondsSinceEpoch,
      'notes': entry.notes,
      'custom_fields': jsonEncode(
        entry.customFields.map((f) => f.toJson()).toList(),
      ),
      'titles': jsonEncode(entry.titles.map((t) => t.toJson()).toList()),
      'projects': jsonEncode(entry.projects.map((p) => p.toJson()).toList()),
      'awards': jsonEncode(entry.awards.map((a) => a.toJson()).toList()),
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
  }

  Future<void> removeHistoryEntry(String id) async {
    final db = await _open();
    await db.delete(_historyTable, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<PersonHistoryEntry>> historyFor(
    String personId,
    HistoryCategory category,
  ) async {
    final db = await _open();
    final rows = await db.query(
      _historyTable,
      where: 'person_id = ? AND category = ?',
      whereArgs: [personId, category.name],
      orderBy: 'start_date ASC',
    );
    return rows.map(_historyFromRow).toList();
  }

  /// Every distinct title already used for [category] across the whole
  /// registry — the searchable-picker's "select if exists" list.
  Future<Set<String>> allHistoryTitles(HistoryCategory category) async {
    final db = await _open();
    final rows = await db.query(
      _historyTable,
      columns: ['title'],
      distinct: true,
      where: "category = ? AND title != ''",
      whereArgs: [category.name],
    );
    return rows.map((r) => r['title'] as String).toSet();
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

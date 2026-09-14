import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite/sqflite.dart' show Database, DatabaseFactory, OpenDatabaseOptions;
import 'package:uuid/uuid.dart';

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

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final path = _path ?? p.join(await _databaseFactory.getDatabasesPath(), 'people.db');
    final db = await _databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE $_personTable (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              avatar_local_id TEXT,
              education TEXT NOT NULL DEFAULT '',
              job TEXT NOT NULL DEFAULT '',
              bio TEXT NOT NULL DEFAULT '',
              relatives_note TEXT NOT NULL DEFAULT '',
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
        },
      ),
    );
    _db = db;
    return db;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Creates a new person under a fresh id, unless [id] is given (demo
  /// seeding's stable-id-for-idempotent-reset trick, same as `Album.isDemo`)
  /// and one already exists at it — then that existing one is returned.
  Future<Person> create({required String name, String? id, bool isDemo = false}) async {
    if (id != null) {
      final existing = await getById(id);
      if (existing != null) return existing;
    }
    final db = await _open();
    final now = DateTime.now();
    final person = Person(id: id ?? _uuid.v4(), name: name, createdAt: now, updatedAt: now, isDemo: isDemo);
    await db.insert(_personTable, _toRow(person));
    return person;
  }

  Future<void> update(Person person) async {
    final db = await _open();
    await db.update(_personTable, _toRow(person), where: 'id = ?', whereArgs: [person.id]);
  }

  Future<Person?> getById(String id) async {
    final db = await _open();
    final rows = await db.query(_personTable, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.single);
  }

  Future<List<Person>> listAll() async {
    final db = await _open();
    final rows = await db.query(_personTable, orderBy: 'created_at ASC');
    return rows.map(_fromRow).toList();
  }

  /// Deletes the person, their photo tags, every relationship touching
  /// them, and their location history. Tagged photos themselves are
  /// untouched — same "membership only" precedent as `AlbumStore.remove`.
  Future<void> remove(String id) async {
    final db = await _open();
    await db.delete(_memberTable, where: 'person_id = ?', whereArgs: [id]);
    await db.delete(_relationshipTable, where: 'person_id = ? OR related_person_id = ?', whereArgs: [id, id]);
    await db.delete(_locationTable, where: 'person_id = ?', whereArgs: [id]);
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
  }

  Future<void> removeAsset(String personId, String localId) async {
    final db = await _open();
    await db.delete(_memberTable, where: 'person_id = ? AND local_id = ?', whereArgs: [personId, localId]);
  }

  Future<List<String>> localIdsIn(String personId) async {
    final db = await _open();
    final rows = await db.query(_memberTable, columns: ['local_id'], where: 'person_id = ?', whereArgs: [personId]);
    return rows.map((r) => r['local_id'] as String).toList();
  }

  // --- Relationships ---

  /// Links [personId] to [relatedPersonId] with [type] — stored both ways
  /// (mirrored, `type`'s inverse for `parent`/`child`) so either profile's
  /// relationship list, and the graph, see it without a second query.
  Future<void> addRelationship(String personId, String relatedPersonId, RelationshipType type) async {
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
      'created_at': now,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
    batch.insert(_relationshipTable, {
      'person_id': relatedPersonId,
      'related_person_id': personId,
      'type': inverse.name,
      'created_at': now,
    }, conflictAlgorithm: sqflite.ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
  }

  Future<void> removeRelationship(String personId, String relatedPersonId) async {
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
    final rows = await db.query(_relationshipTable, where: 'person_id = ?', whereArgs: [personId]);
    return rows.map(_relationshipFromRow).toList();
  }

  /// Every relationship row across all people — powers the graph screen.
  Future<List<PersonRelationship>> allRelationships() async {
    final db = await _open();
    final rows = await db.query(_relationshipTable);
    return rows.map(_relationshipFromRow).toList();
  }

  // --- Location history ---

  Future<void> addLocation(PersonLocation location) async {
    final db = await _open();
    await db.insert(_locationTable, {
      'id': location.id,
      'person_id': location.personId,
      'kind': location.kind.name,
      'place': location.place,
      'since': location.since.millisecondsSinceEpoch,
    });
  }

  Future<void> removeLocation(String id) async {
    final db = await _open();
    await db.delete(_locationTable, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<PersonLocation>> locationsFor(String personId) async {
    final db = await _open();
    final rows = await db.query(_locationTable, where: 'person_id = ?', whereArgs: [personId], orderBy: 'since ASC');
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

  String newId() => _uuid.v4();

  static Map<String, Object?> _toRow(Person person) => {
    'id': person.id,
    'name': person.name,
    'avatar_local_id': person.avatarLocalId,
    'education': person.education,
    'job': person.job,
    'bio': person.bio,
    'relatives_note': person.relativesNote,
    'locked': person.locked ? 1 : 0,
    'passcode_hash': person.passcodeHash,
    'passcode_hint': person.passcodeHint,
    'is_demo': person.isDemo ? 1 : 0,
    'created_at': person.createdAt.millisecondsSinceEpoch,
    'updated_at': person.updatedAt.millisecondsSinceEpoch,
  };

  static Person _fromRow(Map<String, Object?> row) => Person(
    id: row['id'] as String,
    name: row['name'] as String,
    avatarLocalId: row['avatar_local_id'] as String?,
    education: row['education'] as String? ?? '',
    job: row['job'] as String? ?? '',
    bio: row['bio'] as String? ?? '',
    relativesNote: row['relatives_note'] as String? ?? '',
    locked: (row['locked'] as int? ?? 0) != 0,
    passcodeHash: row['passcode_hash'] as String?,
    passcodeHint: row['passcode_hint'] as String?,
    isDemo: (row['is_demo'] as int? ?? 0) != 0,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
  );

  static PersonRelationship _relationshipFromRow(Map<String, Object?> row) => PersonRelationship(
    personId: row['person_id'] as String,
    relatedPersonId: row['related_person_id'] as String,
    type: RelationshipType.values.byName(row['type'] as String),
  );
}

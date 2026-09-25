import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The schema as it shipped at v5 — before details were kept per passcode.
Future<void> _seedV5(String path, {required bool locked}) async {
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 5,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE person (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, avatar_local_id TEXT,
            avatar_face TEXT, bio TEXT NOT NULL DEFAULT '',
            birth_date INTEGER, gender TEXT,
            custom_fields TEXT NOT NULL DEFAULT '[]',
            locked INTEGER NOT NULL DEFAULT 0, passcode_hash TEXT,
            passcode_hint TEXT, is_demo INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE person_asset (
            person_id TEXT NOT NULL, local_id TEXT NOT NULL,
            added_at INTEGER NOT NULL, PRIMARY KEY (person_id, local_id)
          )
        ''');
        await db.execute('''
          CREATE TABLE person_relationship (
            person_id TEXT NOT NULL, related_person_id TEXT NOT NULL,
            type TEXT NOT NULL, organization TEXT,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (person_id, related_person_id)
          )
        ''');
        await db.execute('''
          CREATE TABLE person_location (
            id TEXT PRIMARY KEY, person_id TEXT NOT NULL, kind TEXT NOT NULL,
            place TEXT NOT NULL, since INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE person_history (
            id TEXT PRIMARY KEY, person_id TEXT NOT NULL,
            category TEXT NOT NULL, title TEXT NOT NULL, start_date INTEGER,
            end_date INTEGER, notes TEXT NOT NULL DEFAULT '',
            custom_fields TEXT NOT NULL DEFAULT '[]',
            titles TEXT NOT NULL DEFAULT '[]',
            projects TEXT NOT NULL DEFAULT '[]',
            awards TEXT NOT NULL DEFAULT '[]'
          )
        ''');
      },
    ),
  );
  await db.insert('person', {
    'id': 'mia',
    'name': 'Mia',
    'bio': 'Climbs on Thursdays.',
    'birth_date': DateTime.utc(1990, 4, 2).millisecondsSinceEpoch,
    'gender': 'female',
    'custom_fields': '[{"label":"Coffee","value":"Oat flat white"}]',
    'locked': locked ? 1 : 0,
    'passcode_hash': locked ? hashPasscode('1111') : null,
    'passcode_hint': locked ? 'the office' : null,
    'created_at': 0,
    'updated_at': 0,
  });
  await db.insert('person', {
    'id': 'dan',
    'name': 'Daniel',
    'locked': 0,
    'created_at': 0,
    'updated_at': 0,
  });
  await db.insert('person_relationship', {
    'person_id': 'mia',
    'related_person_id': 'dan',
    'type': 'friend',
    'created_at': 0,
  });
  await db.insert('person_relationship', {
    'person_id': 'dan',
    'related_person_id': 'mia',
    'type': 'friend',
    'created_at': 0,
  });
  await db.close();
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('people_'));
  tearDown(() => dir.deleteSync(recursive: true));

  PersonStore storeAt(String path) {
    final store = PersonStore(databaseFactory: databaseFactoryFfi, path: path);
    addTearDown(store.close);
    return store;
  }

  test('an unlocked profile keeps its details in the open', () async {
    final path = p.join(dir.path, 'people.db');
    await _seedV5(path, locked: false);

    final detail = await storeAt(path).detailFor('mia');

    expect(detail.bio, 'Climbs on Thursdays.');
    expect(
      detail.birthDate?.millisecondsSinceEpoch,
      DateTime.utc(1990, 4, 2).millisecondsSinceEpoch,
    );
    expect(detail.customFields.single.label, 'Coffee');
  });

  test('a locked profile keeps its details behind its own passcode', () async {
    final path = p.join(dir.path, 'people.db');
    await _seedV5(path, locked: true);
    final store = storeAt(path);

    // Nothing in the open set: publishing it on upgrade would undo the one
    // thing the old lock was for.
    expect(await store.detailFor('mia'), PersonDetail.empty);

    // The hash it was locked with still finds it. No keys yet, because a
    // hash is not a passcode and nothing could have encrypted it on the way.
    final migrated = await store.detailFor(
      'mia',
      passcodeHash: hashPasscode('1111'),
    );
    expect(migrated, PersonDetail.empty, reason: 'unsealed needs keys to read');
  });

  test('the old hint survives as the namespace hint', () async {
    final path = p.join(dir.path, 'people.db');
    await _seedV5(path, locked: false);

    expect((await storeAt(path).detailFor('mia')).hint, isEmpty);
  });

  test('relationships survive the key being widened', () async {
    final path = p.join(dir.path, 'people.db');
    await _seedV5(path, locked: false);
    final store = storeAt(path);

    // The table is rebuilt to put the passcode in its key. Dropping and
    // copying is the only way SQLite will do that, so this checks the copy.
    expect((await store.relationshipsFor('mia')).single.relatedPersonId, 'dan');
    expect((await store.relationshipsFor('dan')).single.personId, 'dan');
    expect(await store.allRelationships(), hasLength(2));
  });

  test('upgrading twice is not a second migration', () async {
    final path = p.join(dir.path, 'people.db');
    await _seedV5(path, locked: false);

    final first = storeAt(path);
    await first.detailFor('mia');
    await first.close();

    final again = await storeAt(path).detailFor('mia');
    expect(again.bio, 'Climbs on Thursdays.');
  });
}

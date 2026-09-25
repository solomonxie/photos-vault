import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AlbumKeys _keysFor(String passcode) => AlbumKeys(
  albumKey: Uint8List.fromList(
    List.generate(32, (i) => (i * passcode.hashCode + 7) % 256),
  ),
  entry: PassphraseEntry(
    id: 'entry',
    salt: Uint8List(16),
    verifier: Uint8List(32),
    hint: '',
  ),
);

void main() {
  setUpAll(sqfliteFfiInit);

  PersonStore newStore() {
    final store = PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return store;
  }

  test('the open set is what a profile shows with nothing typed', () async {
    final store = newStore();
    final mia = await store.create(name: 'Mia');

    expect(await store.detailFor(mia.id), PersonDetail.empty);

    await store.saveDetail(mia.id, const PersonDetail(bio: 'Climbs.'));

    expect((await store.detailFor(mia.id)).bio, 'Climbs.');
  });

  test('one passcode cannot see another passcode, or the open set', () async {
    final store = newStore();
    final mia = await store.create(name: 'Mia');
    final work = hashPasscode('1111');
    final family = hashPasscode('2222');

    await store.saveDetail(mia.id, const PersonDetail(bio: 'open'));
    await store.saveDetail(
      mia.id,
      const PersonDetail(bio: 'work', hint: 'the office'),
      passcodeHash: work,
      keys: _keysFor('1111'),
    );
    await store.saveDetail(
      mia.id,
      const PersonDetail(bio: 'family'),
      passcodeHash: family,
      keys: _keysFor('2222'),
    );

    expect((await store.detailFor(mia.id)).bio, 'open');
    expect(
      (await store.detailFor(
        mia.id,
        passcodeHash: work,
        keys: _keysFor('1111'),
      )).bio,
      'work',
    );
    expect(
      (await store.detailFor(
        mia.id,
        passcodeHash: family,
        keys: _keysFor('2222'),
      )).bio,
      'family',
    );
  });

  test('a passcode nobody has used is empty, not an error', () async {
    final store = newStore();
    final mia = await store.create(name: 'Mia');
    await store.saveDetail(
      mia.id,
      const PersonDetail(bio: 'work'),
      passcodeHash: hashPasscode('1111'),
      keys: _keysFor('1111'),
    );

    final unused = await store.detailFor(
      mia.id,
      passcodeHash: hashPasscode('9999'),
      keys: _keysFor('9999'),
    );

    expect(unused, PersonDetail.empty);
  });

  test('the right hash with the wrong keys still shows nothing', () async {
    final store = newStore();
    final mia = await store.create(name: 'Mia');
    final hash = hashPasscode('1111');
    await store.saveDetail(
      mia.id,
      const PersonDetail(bio: 'work'),
      passcodeHash: hash,
      keys: _keysFor('1111'),
    );

    // A phone that knows where to look but cannot derive the key — a
    // different passphrase, or one that was forgotten on this device.
    final blocked = await store.detailFor(
      mia.id,
      passcodeHash: hash,
      keys: _keysFor('other'),
    );

    expect(blocked, PersonDetail.empty);
    expect(
      await store.detailFor(mia.id, passcodeHash: hash),
      PersonDetail.empty,
      reason: 'and without keys at all',
    );
  });

  test('a hidden set is not readable from the row itself', () async {
    final store = newStore();
    final mia = await store.create(name: 'Mia');
    await store.saveDetail(
      mia.id,
      const PersonDetail(bio: 'a secret worth keeping'),
      passcodeHash: hashPasscode('1111'),
      keys: _keysFor('1111'),
    );

    // What a backup zip, or anyone reading the database file, gets.
    final rows = await store.changeLogRows();
    final dump = rows.map((r) => '${r['after']}').join();

    expect(dump, isNot(contains('a secret worth keeping')));
  });

  test('saving under a passcode with no keys writes nothing', () async {
    final store = newStore();
    final mia = await store.create(name: 'Mia');

    await store.saveDetail(
      mia.id,
      const PersonDetail(bio: 'would be in the clear'),
      passcodeHash: hashPasscode('1111'),
    );

    expect(
      await store.detailFor(
        mia.id,
        passcodeHash: hashPasscode('1111'),
        keys: _keysFor('1111'),
      ),
      PersonDetail.empty,
    );
  });
}

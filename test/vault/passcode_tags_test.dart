import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/settings/secure_store.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/passcode_tags.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MemoryStore implements SecureStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _LockedStore implements SecureStore {
  @override
  Future<String?> read(String key) => throw const FileSystemException('locked');

  @override
  Future<void> write(String key, String value) =>
      throw const FileSystemException('locked');

  @override
  Future<void> delete(String key) async {}
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('pv_tags_'));
  tearDown(() => dir.delete(recursive: true));

  AssetRecordStore records() {
    final s = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, 'photos_vault.db'),
    );
    addTearDown(s.close);
    return s;
  }

  PersonStore people() {
    final s = PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, 'people.db'),
    );
    addTearDown(s.close);
    return s;
  }

  Future<void> hidden(AssetRecordStore s, String id, String tag) async {
    await s.upsert(localId: id, contentHash: id, platform: 'ios');
    await s.setPasscodeHash(id, tag);
  }

  VaultKeys vault(SecureStore store) =>
      VaultKeys(store: store, derive: deriveOnThisIsolate);

  test(
    'an old hash still opens its album, and is upgraded on unlock',
    () async {
      final s = records();
      final ppl = people();
      final keychain = _MemoryStore();
      final keys = vault(keychain);
      await keys.add('correct horse battery');
      await hidden(s, 'photo:a', hashPasscode('1234'));
      final person = await ppl.create(name: 'Mia');
      final album = (await keys.activeAlbumKeys('1234'))!;
      await ppl.saveDetail(
        person.id,
        const PersonDetail(bio: 'sealed'),
        scope: PersonScope.sealed(hashPasscode('1234'), album),
      );

      final tags = PasscodeTags(
        records: s,
        people: ppl,
        vaultKeys: keys,
        store: keychain,
      );
      final tag = await tags.tagFor('1234');

      expect(tag, isNot(hashPasscode('1234')));
      expect(tag, startsWith(tagPrefix));
      expect((await s.forPasscodeHash(tag)).single.localId, 'photo:a');
      expect(await s.passcodeHashes(), {tag});
      expect(await ppl.namespaces(), {tag});
      final detail = await ppl.detailFor(
        person.id,
        passcodeHash: tag,
        keys: album,
      );
      expect(detail.bio, 'sealed', reason: 'the seal is not bound to the tag');
      // Same code, same tag; a different code, a different album.
      expect(await tags.tagFor('1234'), tag);
      expect(await tags.tagFor('4321'), isNot(tag));
    },
  );

  test(
    'old tags are reversed and upgraded at launch, with no code typed',
    () async {
      final s = records();
      final ppl = people();
      final keychain = _MemoryStore();
      final person = await ppl.create(name: 'Mia');
      await hidden(s, 'photo:a', hashPasscode('0420'));
      await hidden(
        s,
        'photo:b',
        hashPasscode(personAlbumCode(person.id, '7777')),
      );
      final tags = PasscodeTags(
        records: s,
        people: ppl,
        vaultKeys: vault(keychain),
        store: keychain,
      );

      expect(await tags.upgradeLegacy(), 2);
      expect((await s.passcodeHashes()).where(isLegacyTag), isEmpty);
      final album = await tags.tagFor('0420');
      expect((await s.forPasscodeHash(album)).single.localId, 'photo:a');
      final folder = await tags.tagFor(personAlbumCode(person.id, '7777'));
      expect((await s.forPasscodeHash(folder)).single.localId, 'photo:b');
    },
  );

  test('a lost keychain key comes back from its escrow', () async {
    final s = records();
    final ppl = people();
    final keychain = _MemoryStore();
    final keys = vault(keychain);
    await keys.add('correct horse battery');
    final tag = await PasscodeTags(
      records: s,
      people: ppl,
      vaultKeys: keys,
      store: keychain,
    ).tagFor('1234');
    await hidden(s, 'photo:a', tag);

    // A restore without the keychain: no tag key, no master key. The
    // passphrase entry comes back from the bucket's index.
    final entry = (await keys.entries()).single;
    final fresh = _MemoryStore();
    final newPhone = vault(fresh);
    expect(await newPhone.unlockEntry(entry, 'correct horse battery'), isTrue);
    final again = await PasscodeTags(
      records: s,
      people: ppl,
      vaultKeys: newPhone,
      store: fresh,
    ).tagFor('1234');

    expect(again, tag);
    expect((await s.forPasscodeHash(again)).single.localId, 'photo:a');
  });

  test(
    'with no key and no passphrase yet, nothing is lost: typed later, it opens',
    () async {
      final s = records();
      final ppl = people();
      final keychain = _MemoryStore();
      final keys = vault(keychain);
      await keys.add('correct horse battery');
      final entry = (await keys.entries()).single;
      final tag = await PasscodeTags(
        records: s,
        people: ppl,
        vaultKeys: keys,
        store: keychain,
      ).tagFor('1234');
      await hidden(s, 'photo:a', tag);

      final fresh = _MemoryStore();
      final newPhone = vault(fresh);
      final tags = PasscodeTags(
        records: s,
        people: ppl,
        vaultKeys: newPhone,
        store: fresh,
      );
      final before = await tags.tagFor('1234');
      expect(before, isNot(tag), reason: 'a new key, minted');
      expect(await s.getByLocalId('photo:a'), isNotNull);
      expect(await s.passcodeHashes(), {tag}, reason: 'the row is untouched');

      await newPhone.unlockEntry(entry, 'correct horse battery');
      final after = await tags.tagFor('1234');
      expect(after, before);
      expect((await s.forPasscodeHash(after)).single.localId, 'photo:a');
    },
  );

  test('an unreadable keychain falls back to the old form', () async {
    final s = records();
    await hidden(s, 'photo:a', hashPasscode('1234'));
    final tags = PasscodeTags(
      records: s,
      people: people(),
      vaultKeys: vault(_MemoryStore()),
      store: _LockedStore(),
    );

    final tag = await tags.tagFor('1234');
    expect(tag, hashPasscode('1234'));
    expect((await s.forPasscodeHash(tag)).single.localId, 'photo:a');
    expect(await tags.upgradeLegacy(), 0);
    expect(await s.passcodeHashes(), {hashPasscode('1234')});
  });

  test('the ring follows its album to the new tag', () async {
    final s = records();
    final keychain = _MemoryStore();
    final keys = vault(keychain);
    await keys.add('correct horse battery');
    final legacy = hashPasscode('1234');
    await keys.unlockAlbum('1234', legacy);
    await hidden(s, 'photo:a', legacy);
    await keys.keepAlbum(legacy);

    final tag = await PasscodeTags(
      records: s,
      people: people(),
      vaultKeys: keys,
      store: keychain,
    ).tagFor('1234');

    expect(keys.ringKeysFor(legacy), isNull);
    expect(keys.ringKeysFor(tag), isNotNull);
    expect(await keys.ringTags(), {tag});
  });
}

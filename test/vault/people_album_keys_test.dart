import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/passcode_tags.dart';
import 'package:photos_vault/vault/people_album_keys.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

void main() {
  late FakeAssetRecordStore records;
  late FakePersonStore people;
  late VaultKeys keys;

  setUp(() async {
    records = FakeAssetRecordStore();
    people = FakePersonStore();
    keys = VaultKeys(store: FakeSecureStore(), derive: deriveOnThisIsolate)
      ..lockAll();
    await keys.add('a good long passphrase');
  });

  test(
    "one code puts every person's hidden folder on the ring, and only those",
    () async {
      final mia = await people.create(name: 'Mia');
      final leo = await people.create(name: 'Leo');
      await people.create(name: 'Ana');
      final tags = PasscodeTags(records: records, vaultKeys: keys);
      final miaTag = await tags.tagFor(personAlbumCode(mia.id, '1234'));
      final leoTag = await tags.tagFor(personAlbumCode(leo.id, '1234'));
      final other = await tags.tagFor(personAlbumCode(leo.id, '9999'));
      for (final (id, tag) in [('a', miaTag), ('b', leoTag), ('c', other)]) {
        await records.upsert(localId: id, contentHash: id, platform: 'ios');
        await records.setPasscodeHash(id, tag);
      }

      final kept = await keepPeopleAlbums(
        records: records,
        people: people,
        keys: keys,
        digits: '1234',
      );

      expect(kept, 2);
      expect(keys.unlockedHashes.toSet(), {miaTag, leoTag});
      expect(await keys.ringTags(), containsAll([miaTag, leoTag]));
    },
  );
}

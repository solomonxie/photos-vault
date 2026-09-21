import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/secure_store.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/vault/keys.dart';

class _MemoryStore implements SecureStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  test('a passphrase is remembered as a key, never as itself', () async {
    final store = _MemoryStore();
    final keys = VaultKeys(store: store);

    await keys.add('correct horse battery', hint: 'the usual one');

    expect(
      store.values.values.any((v) => v.contains('correct horse battery')),
      isFalse,
      reason: 'nothing may hold the typed passphrase',
    );
    final entries = await keys.entries();
    expect(entries.single.hint, 'the usual one');
    expect(entries.single.salt.length, 16);
  });

  test(
    'wrong digits derive a different album key, with no error to give',
    () async {
      final keys = VaultKeys(store: _MemoryStore());
      await keys.add('correct horse battery');

      final right = await keys.activeAlbumKeys('1234');
      final wrong = await keys.activeAlbumKeys('9999');
      expect(right, isNotNull);
      expect(wrong, isNotNull, reason: 'a wrong code is still a code');
      expect(right!.albumKey, isNot(equals(wrong!.albumKey)));
      expect(right.sectionTag, isNot(equals(wrong.sectionTag)));
    },
  );

  test('an old passphrase can be added back, and both stay', () async {
    final store = _MemoryStore();
    final first = VaultKeys(store: store);
    final old = await first.add('the old one', hint: 'old phone');

    // A new phone: the entry came out of the bucket, its key never left the
    // old phone's keychain.
    final fresh = _MemoryStore();
    final second = VaultKeys(store: fresh);
    await second.add('the new one', hint: 'this phone');

    expect(await second.unlockEntry(old, 'wrong guess'), isFalse);
    expect(await second.unlockEntry(old, 'the old one'), isTrue);
    expect((await second.entries()).length, 2);

    final all = await second.albumKeys('1234');
    expect(all.length, 2, reason: 'both generations open');
  });

  test('the ring holds keys by hash, and lets go when told', () async {
    final keys = VaultKeys(store: _MemoryStore());
    await keys.add('correct horse battery');

    expect(keys.ringKeysFor(hashPasscode('1234')), isNull);
    await keys.unlockAlbum('1234');
    expect(keys.ringKeysFor(hashPasscode('1234')), isNotNull);
    expect(keys.ringKeysFor(hashPasscode('4321')), isNull);

    keys.lockAll();
    expect(keys.ringKeysFor(hashPasscode('1234')), isNull);
  });

  test('forgetting on this phone leaves the entry but loses the key', () async {
    final store = _MemoryStore();
    final keys = VaultKeys(store: store);
    await keys.add('correct horse battery');
    await keys.forgetOnThisDevice();

    expect((await keys.entries()).length, 1, reason: 'the hint survives');
    expect(await keys.albumKeys('1234'), isEmpty);
  });

  test('a verifier tells a right passphrase from a wrong one', () async {
    final keys = VaultKeys(store: _MemoryStore());
    final entry = await keys.add('correct horse battery');
    expect(entry.verifier.length, 32);
    expect(entry.verifier, isNot(equals(Uint8List(32))));
  });
}

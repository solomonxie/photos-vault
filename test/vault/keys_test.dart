import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/settings/secure_store.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/vault/keys.dart';

/// Set on the test's own isolate only; a fresh isolate sees the initial 0.
var _isolateMark = 0;

/// Reports, as the derived key, which isolate it ran on.
class _MarkingCipher implements VaultCipher {
  @override
  Uint8List deriveKey({
    required String passphrase,
    required Uint8List salt,
    required int iterations,
    int length = 32,
  }) => Uint8List(length)..fillRange(0, length, _isolateMark);

  @override
  Uint8List transform({
    required Uint8List key,
    required Uint8List iv,
    required Uint8List data,
  }) => data;
}

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

  test(
    'an unlocked album comes back after a relaunch, until forgotten',
    () async {
      final store = _MemoryStore();
      final keys = VaultKeys(store: store);
      await keys.add('correct horse battery');
      final opened = (await keys.unlockAlbum('1234'))!;
      await keys.keepAlbum(hashPasscode('1234'));
      keys.lockAll();

      final relaunched = VaultKeys(store: store);
      await relaunched.restoreRing();
      final back = relaunched.ringKeysFor(hashPasscode('1234'))!;
      expect(back.albumKey, opened.albumKey);
      expect(store.values.values.any((v) => v.contains('1234')), isFalse);

      await relaunched.forgetOnThisDevice();
      await VaultKeys(store: store).restoreRing();
      expect(relaunched.ringKeysFor(hashPasscode('1234')), isNull);
    },
  );

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

  test(
    'the outbox key needs no code, and is the same for every album',
    () async {
      final keys = VaultKeys(store: _MemoryStore());
      final entry = await keys.add('correct horse battery');

      final a = (await keys.albumKeys('1234')).single;
      final b = (await keys.albumKeys('9999')).single;

      expect(a.outboxKey, isNotNull);
      expect(a.outboxKey, b.outboxKey);
      expect(await keys.outboxKey(entry.id), a.outboxKey);
      expect(a.outboxKey, isNot(a.albumKey));
      expect(await keys.outboxKey('nobody'), isNull);
    },
  );

  test(
    'a code typed into an empty album is not kept across launches',
    () async {
      final store = _MemoryStore();
      final keys = VaultKeys(store: store);
      await keys.add('correct horse battery');
      await keys.unlockAlbum('9876');
      keys.lockAll();

      final relaunched = VaultKeys(store: store);
      await relaunched.restoreRing();
      expect(relaunched.ringKeysFor(hashPasscode('9876')), isNull);
    },
  );

  test('the passphrase is stretched off the UI isolate', () async {
    _isolateMark = 7;
    final keys = VaultKeys(store: _MemoryStore(), cipher: _MarkingCipher());
    await keys.add('correct horse battery');

    final master = await deriveOnThisIsolate(
      _MarkingCipher(),
      'x',
      Uint8List(16),
    );
    expect(master.first, 7, reason: 'the mark is visible here');
    final album = (await keys.albumKeys('1234')).single;
    final derivedThere = hkdf(
      key: Uint8List(32),
      info: utf8.encode('album:1234'),
    ).sublist(0, 32);
    expect(
      album.albumKey,
      derivedThere,
      reason: 'the master key came from an isolate that never saw the mark',
    );
  });

  test('setup on a new phone lands on the old salt when the old passphrase '
      'is typed, and mints a new one otherwise', () async {
    final old = await VaultKeys(store: _MemoryStore())
        .add('the old one', hint: 'old phone');

    final phone = VaultKeys(store: _MemoryStore());
    final again = await phone.setUp('the old one', known: [old]);
    expect(again.id, old.id);
    expect(again.salt, old.salt);
    expect((await phone.entries()).single.id, old.id);

    final other = VaultKeys(store: _MemoryStore());
    final fresh = await other.setUp('something else', known: [old]);
    expect(fresh.id, isNot(old.id));
  });

  test('a passphrase entry made before this change still opens', () async {
    // Built by hand the way every earlier build did: PBKDF2-SHA256 600k
    // over a 16-byte salt, verifier and id by HMAC, album key by HKDF.
    final cipher = PlatformCipher();
    final salt = Uint8List.fromList(List.generate(16, (i) => 200 - i));
    final master = cipher.deriveKey(
      passphrase: 'an older passphrase',
      salt: salt,
      iterations: 600000,
    );
    final entry = PassphraseEntry(
      id: base64Url.encode(vaultHmac(salt, 'id'.codeUnits).sublist(0, 9)),
      salt: salt,
      verifier: vaultHmac(master, 'verify'.codeUnits),
      hint: '',
    );
    final albumKey = hkdf(
      key: master,
      info: utf8.encode('album:2468'),
    ).sublist(0, 32);

    final phone = VaultKeys(store: _MemoryStore());
    expect(
      (await phone.setUp('an older passphrase', known: [entry])).id,
      entry.id,
    );
    expect((await phone.albumKeys('2468')).single.albumKey, albumKey);
  });
}

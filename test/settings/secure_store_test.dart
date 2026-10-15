import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/secure_store.dart';

/// A keychain of named items, each old (readable only unlocked) or current,
/// with a failure that can be armed at any one step.
class _Keychain implements Keychain {
  final items = <String, ({String value, bool current})>{};

  /// `readAll`, `read:<name>`, `write:<name>`, `delete:<name>`.
  final failing = <String>{};

  /// A write that lands something other than what it was given.
  final garbling = <String>{};

  var locked = false;

  void _maybeFail(String step) {
    if (failing.contains(step)) throw StateError('keychain: $step');
  }

  @override
  Future<String?> read(String name) async {
    _maybeFail('read:$name');
    final item = items[name];
    if (item == null) return null;
    if (locked && !item.current) throw StateError('interaction not allowed');
    return item.value;
  }

  @override
  Future<void> write(String name, String value) async {
    _maybeFail('write:$name');
    items[name] = (
      value: garbling.contains(name) ? '$value?' : value,
      current: true,
    );
  }

  @override
  Future<void> delete(String name) async {
    _maybeFail('delete:$name');
    items.remove(name);
  }

  @override
  Future<Map<String, String>> readAll() async {
    _maybeFail('readAll');
    return {for (final e in items.entries) e.key: e.value.value};
  }

  void seedOld(String name, String value) =>
      items[name] = (value: value, current: false);
}

void main() {
  const copy = FlutterSecureStore.currentName;

  Future<void> expectEveryKeyReads(FlutterSecureStore store) async {
    expect(await store.read('backup_targets_v1'), '[bucket]');
    expect(await store.read('vault_ring'), 'album-key');
  }

  ({_Keychain keychain, FlutterSecureStore store}) setUpOld() {
    final keychain = _Keychain()
      ..seedOld('backup_targets_v1', '[bucket]')
      ..seedOld('vault_ring', 'album-key');
    return (keychain: keychain, store: FlutterSecureStore(keychain: keychain));
  }

  test('migrated, the keys read while the phone is locked', () async {
    final s = setUpOld();
    expect(await s.store.migrate(), isTrue);

    expect(s.keychain.items.keys.toSet(), {
      copy('backup_targets_v1'),
      copy('vault_ring'),
    });
    s.keychain.locked = true;
    await expectEveryKeyReads(s.store);
  });

  for (final step in [
    'readAll',
    'read:${copy('vault_ring')}',
    'write:${copy('vault_ring')}',
    'delete:vault_ring',
  ]) {
    test(
      'a failure at $step loses no key, and the next launch finishes',
      () async {
        final s = setUpOld();
        s.keychain.failing.add(step);

        expect(await s.store.migrate(), isFalse);
        expect(
          s.keychain.items['vault_ring']?.value,
          'album-key',
          reason: 'the old item stays until its copy is proven',
        );

        s.keychain.failing.clear();
        await expectEveryKeyReads(s.store);
        expect(await s.store.migrate(), isTrue);
        await expectEveryKeyReads(s.store);
        expect(s.keychain.items.containsKey('vault_ring'), isFalse);
      },
    );
  }

  test('a copy that reads back wrong is dropped; the old item stays', () async {
    final s = setUpOld();
    s.keychain.garbling.add(copy('vault_ring'));

    expect(await s.store.migrate(), isFalse);
    expect(s.keychain.items['vault_ring']?.value, 'album-key');
    expect(s.keychain.items.containsKey(copy('vault_ring')), isFalse);
    await expectEveryKeyReads(s.store);
  });

  test('a read-back that fails keeps the old item', () async {
    // Fails only after the copy is written: the second read of the name.
    var reads = 0;
    final name = copy('vault_ring');
    final keychain = _Keychain()
      ..seedOld('backup_targets_v1', '[bucket]')
      ..seedOld('vault_ring', 'album-key');
    final store = FlutterSecureStore(
      keychain: _Counting(keychain, name, () => ++reads == 2),
    );

    expect(await store.migrate(), isFalse);
    expect(keychain.items['vault_ring']?.value, 'album-key');
    expect(await store.read('vault_ring'), 'album-key');
  });

  test(
    'a write made during the migration is never overwritten by it',
    () async {
      final s = setUpOld();
      final migrating = s.store.migrate();
      final writing = s.store.write('vault_ring', 'newer-key');
      await Future.wait([migrating, writing]);

      expect(await s.store.read('vault_ring'), 'newer-key');
      expect(s.keychain.items.containsKey('vault_ring'), isFalse);
    },
  );

  test('a delete leaves nothing for a read to fall back to', () async {
    final s = setUpOld();
    await s.store.write('vault_ring', 'v2');
    s.keychain.seedOld('vault_ring', 'stale');

    await s.store.delete('vault_ring');
    expect(await s.store.read('vault_ring'), isNull);
  });
}

/// Fails `read(name)` when [failNow] says so.
class _Counting implements Keychain {
  _Counting(this.inner, this.name, this.failNow);

  final _Keychain inner;
  final String name;
  final bool Function() failNow;

  @override
  Future<String?> read(String n) async {
    if (n == name && failNow()) throw StateError('read back failed');
    return inner.read(n);
  }

  @override
  Future<void> write(String n, String value) => inner.write(n, value);

  @override
  Future<void> delete(String n) => inner.delete(n);

  @override
  Future<Map<String, String>> readAll() => inner.readAll();
}

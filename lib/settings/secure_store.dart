import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../demo/demo_flag.dart';

/// Thin wrapper around secure key/value storage so settings persistence is
/// testable without a platform channel (Keychain on iOS, Keystore on Android).
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// The keychain item by item, the seam [FlutterSecureStore] and
/// [FlutterSecureStore.migrate] are tested through.
///
/// Two classes of item: the old ones, readable only while the phone is
/// unlocked, and the current ones, readable once it has been unlocked since
/// boot — what a background pass on the charger at 3 a.m. needs. Not
/// `ThisDeviceOnly`: an encrypted device backup brings the keys back.
abstract class Keychain {
  /// Any item named [name], whatever its class.
  Future<String?> read(String name);

  /// Written as a current (after-first-unlock) item.
  Future<void> write(String name, String value);

  /// Every item named [name], whatever its class.
  Future<void> delete(String name);

  /// Every item, by name, whatever its class.
  Future<Map<String, String>> readAll();
}

class PlatformKeychain implements Keychain {
  const PlatformKeychain();

  // No accessibility in the query: matches an item of either class.
  static const _any = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: null),
  );
  static const _current = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  @override
  Future<String?> read(String name) => _any.read(key: name);

  @override
  Future<void> write(String name, String value) =>
      _current.write(key: name, value: value);

  @override
  Future<void> delete(String name) => _any.delete(key: name);

  @override
  Future<Map<String, String>> readAll() => _any.readAll();
}

/// Keys are kept under a new item name in the current class, so the old
/// item is never touched until the new one has been read back: a keychain
/// item's class can't be changed in place, and delete-then-write loses the
/// key if anything dies in between.
///
/// A read takes the current item, else the old one. Nothing here ever
/// changes what a read returns except [write] and [delete].
class FlutterSecureStore implements SecureStore {
  const FlutterSecureStore({this._keychain = const PlatformKeychain()});

  final Keychain _keychain;

  static const currentSuffix = '.after_first_unlock';

  static String currentName(String name) => '$name$currentSuffix';

  /// Demo mode keeps its own keys: never the real buckets or AI keys.
  static String _scoped(String key) => DemoFlag.active ? 'demo.$key' : key;

  /// Writes, deletes and the migration, one at a time: a migration copying
  /// an old value must not land over a write made meanwhile.
  static Future<void> _tail = Future.value();

  static Future<T> _serial<T>(Future<T> Function() action) {
    final run = _tail.then((_) => action());
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  @override
  Future<String?> read(String key) async {
    final name = _scoped(key);
    return await _keychain.read(currentName(name)) ??
        await _keychain.read(name);
  }

  @override
  Future<void> write(String key, String value) => _serial(() async {
    final name = _scoped(key);
    await _keychain.write(currentName(name), value);
    try {
      await _keychain.delete(name);
    } catch (_) {
      // Shadowed by the current item; the migration retries it.
    }
  });

  /// The old item first: were it left behind, a read would fall back to it.
  @override
  Future<void> delete(String key) => _serial(() async {
    final name = _scoped(key);
    await _keychain.delete(name);
    await _keychain.delete(currentName(name));
  });

  /// Every item whose name starts with [prefix], either class.
  Future<void> deleteWhere(String prefix) => _serial(() async {
    for (final name in (await _keychain.readAll()).keys) {
      if (name.startsWith(prefix)) await _keychain.delete(name);
    }
  });

  /// Moves every old item to the current class, once, in the foreground.
  /// Per item: write the copy, read it back, compare, and only then remove
  /// the old one. Any failure keeps the old item for the next launch. True
  /// when nothing old is left.
  Future<bool> migrate() => _serial(() async {
    final Map<String, String> all;
    try {
      all = await _keychain.readAll();
    } catch (_) {
      return false;
    }
    var done = true;
    for (final MapEntry(key: name, value: value) in all.entries) {
      if (name.endsWith(currentSuffix)) continue;
      final copy = currentName(name);
      try {
        // Already there: written since, so newer; or an earlier pass's copy.
        if (!all.containsKey(copy) && await _keychain.read(copy) == null) {
          await _keychain.write(copy, value);
          if (await _keychain.read(copy) != value) {
            await _dropBadCopy(copy);
            done = false;
            continue;
          }
        }
        await _keychain.delete(name);
      } catch (_) {
        done = false;
      }
    }
    return done;
  });

  /// A copy that read back wrong would shadow the good old item.
  Future<void> _dropBadCopy(String copy) async {
    try {
      await _keychain.delete(copy);
    } catch (_) {}
  }
}

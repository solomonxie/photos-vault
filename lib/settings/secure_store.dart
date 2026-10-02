import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../demo/demo_flag.dart';

/// Thin wrapper around secure key/value storage so settings persistence is
/// testable without a platform channel (Keychain on iOS, Keystore on Android).
abstract class SecureStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureStore implements SecureStore {
  const FlutterSecureStore();

  static const _storage = FlutterSecureStorage();

  /// Demo mode keeps its own keys: never the real buckets or AI keys.
  static String _scoped(String key) => DemoFlag.active ? 'demo.$key' : key;

  @override
  Future<String?> read(String key) => _storage.read(key: _scoped(key));

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: _scoped(key), value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: _scoped(key));
}

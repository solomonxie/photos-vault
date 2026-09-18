import 'package:photos_vault/settings/secure_store.dart';

class FakeSecureStore implements SecureStore {
  final Map<String, String> _values = {};

  /// Synchronous test-setup helper — primes a value without going through
  /// the (trivially-resolving, but still async) [write].
  void seed(String key, String value) => _values[key] = value;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

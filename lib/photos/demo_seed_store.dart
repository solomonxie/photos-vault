import '../settings/secure_store.dart';

/// Tracks whether the one-time initial demo-photo seeding has already run.
/// A fresh install shows demo content immediately without the user tapping
/// "Try with Demo Photos" — but once seeded, deleting that content later
/// doesn't bring it back on the next launch; only the explicit "Reset Demo
/// Data" utility does that.
class DemoSeedStore {
  DemoSeedStore({SecureStore? store}) : _store = store ?? const FlutterSecureStore();

  final SecureStore _store;

  /// Exposed so tests can pre-seed a [FakeSecureStore] directly, without
  /// going through the async [markSeeded] write.
  static const seededKey = 'demo_data_seeded_v1';

  Future<bool> hasSeeded() async => (await _store.read(seededKey)) != null;

  Future<void> markSeeded() => _store.write(seededKey, 'true');
}

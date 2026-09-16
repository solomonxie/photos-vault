import '../storage/asset_record_store.dart';

/// Tracks whether the one-time initial demo-photo seeding has already run.
/// A fresh install shows demo content immediately without the user tapping
/// "Try with Demo Photos" — but once seeded, deleting that content later
/// doesn't bring it back on the next launch; only the explicit "Reset Demo
/// Data" utility does that.
///
/// Kept in the asset database rather than in secure storage, because on iOS
/// Keychain items **survive an uninstall** and the app's database doesn't.
/// A flag that outlives the records it describes leaves a reinstalled app
/// certain it has already seeded a library that is, in fact, empty — which
/// is exactly what it looked like: reinstall, and the app comes up blank
/// with no demo content and no way back to it short of Reset Demo Data.
class DemoSeedStore {
  DemoSeedStore({required this.recordStore});

  final AssetRecordStore recordStore;

  static const seededKey = 'demo_data_seeded_v1';

  Future<bool> hasSeeded() async =>
      (await recordStore.getAppState(seededKey)) != null;

  Future<void> markSeeded() => recordStore.setAppState(seededKey, 'true');
}

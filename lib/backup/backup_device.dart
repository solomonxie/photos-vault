import 'package:uuid/uuid.dart';

import '../storage/asset_record_store.dart';
import 'app_snapshot.dart';
import 'snapshot_archive.dart';

/// Which device a daily copy is from, so two phones on one bucket or one
/// iCloud account never overwrite each other's day.
///
/// Seeded from cloud sync's device id (`sync.db`) and then kept in app
/// state, so a later sync reset doesn't move this phone's copies. App state
/// is not in any snapshot: a restored install gets its own id.
class BackupDevice {
  BackupDevice({required this.snapshots, required this.settings});

  final AppSnapshotIo snapshots;
  final AssetRecordStore settings;

  static const key = 'backup_device_id';

  String? _id;

  Future<String> id() async {
    if (_id case final known?) return known;
    final stored = await settings.getAppState(key);
    if (stored != null && isDeviceId(stored)) return _id = stored;
    String? seed;
    try {
      seed = await snapshots.syncStore?.device();
    } catch (_) {}
    final made = seed != null && isDeviceId(seed) ? seed : const Uuid().v4();
    await settings.setAppState(key, made);
    return _id = made;
  }
}

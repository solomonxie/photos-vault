import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'file_hash.dart';

const _videoExtensions = {'.mp4', '.mov', '.m4v'};

bool _isVideoPath(String path) =>
    _videoExtensions.any(path.toLowerCase().endsWith);

/// Manual add flow (T2.5): lets the user pick files directly — from the
/// Files app / iCloud Drive, or photos/videos via the system picker — and
/// enqueues them into `asset_record` alongside auto-detected camera-roll
/// assets. This is also how the iOS Share Extension (T2.6) feeds the same
/// queue for anything shared in from another app.
///
/// The picked path is a picker-owned temp copy, not something this app owns
/// — the OS can clear it any time, and its absolute prefix goes stale on
/// every reinstall regardless (container UUIDs aren't stable across
/// installs). So the file is copied into app-owned storage, hash-named,
/// before it's ever recorded — same fix `DemoAssetsService` already needed.
class ManualAddService {
  ManualAddService({
    required this.store,
    this.picker = FilePicker.pickFiles,
    Future<Directory> Function()? targetDirectory,
  }) : _targetDirectory = targetDirectory ?? getApplicationSupportDirectory;

  final AssetRecordStore store;
  final Future<Directory> Function() _targetDirectory;

  /// Overridable for tests so they never touch the real file picker.
  final Future<List<PlatformFile>> Function({FileType type, bool allowMultiple})
  picker;

  /// Opens the picker and enqueues every picked file. `localId` is derived
  /// from the file's content hash, so re-picking the same file is a no-op
  /// rather than a duplicate.
  Future<List<AssetRecord>> pickAndEnqueue() async {
    final files = await picker(type: FileType.any, allowMultiple: true);
    final added = <AssetRecord>[];
    for (final file in files) {
      final path = file.path;
      if (path == null) continue;
      final record = await enqueueFile(path);
      added.add(record);
    }
    return added;
  }

  /// Enqueues a single file already on disk — shared by [pickAndEnqueue] and
  /// the share extension's intent handler. Copies it into app-owned storage
  /// first, keyed by content hash, so re-adding the same content is a no-op
  /// and the record never points at a path this app doesn't control.
  Future<AssetRecord> enqueueFile(String path, {DateTime? createdAt}) async {
    final hash = await hashFile(path);
    final dir = await _targetDirectory();
    final owned = File(p.join(dir.path, '$hash${p.extension(path)}'));
    if (!await owned.exists()) await File(path).copy(owned.path);
    return store.upsert(
      localId: 'manual:$hash',
      contentHash: hash,
      platform: Platform.isIOS ? 'ios' : 'android',
      sourceType: AssetSourceType.manualFile,
      sourcePath: owned.path,
      isVideo: _isVideoPath(path),
      createdAt: createdAt,
    );
  }
}

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';

/// Manual add flow (T2.5): lets the user pick files directly — from the
/// Files app / iCloud Drive, or photos/videos via the system picker — and
/// enqueues them into `asset_record` alongside auto-detected camera-roll
/// assets. This is also how the iOS Share Extension (T2.6) feeds the same
/// queue for anything shared in from another app.
class ManualAddService {
  ManualAddService({required this.store, this.picker = FilePicker.pickFiles});

  final AssetRecordStore store;

  /// Overridable for tests so they never touch the real file picker.
  final Future<List<PlatformFile>> Function({FileType type, bool allowMultiple}) picker;

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
  /// the share extension's intent handler.
  Future<AssetRecord> enqueueFile(String path) async {
    final hash = await _hashFile(path);
    return store.upsert(
      localId: 'manual:$hash',
      contentHash: hash,
      platform: Platform.isIOS ? 'ios' : 'android',
      sourceType: AssetSourceType.manualFile,
      sourcePath: path,
    );
  }

  static Future<String> _hashFile(String path) async {
    final digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }
}

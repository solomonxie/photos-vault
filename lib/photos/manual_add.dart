import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/capture_date.dart';
import 'file_hash.dart';

const _videoExtensions = {'.mp4', '.mov', '.m4v'};

bool _isVideoPath(String path) =>
    _videoExtensions.any(path.toLowerCase().endsWith);

/// A GIF is a still this app can decode, so it is never [isVideo] — but it
/// moves, so it is filed with the videos. See [AssetRecord.countsAsVideo].
bool isGifPath(String path) => path.toLowerCase().endsWith('.gif');

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
  ///
  /// [passcodeHash] and [isHidden] make a new row hidden from its first
  /// write (a copy of a hidden photo).
  Future<AssetRecord> enqueueFile(
    String path, {
    DateTime? createdAt,
    String? passcodeHash,
    bool isHidden = false,
    bool isArchived = false,
    DateTime? fallbackDate,
  }) async {
    final hash = await hashFile(path);
    final dir = await _targetDirectory();
    final owned = File(p.join(dir.path, '$hash${p.extension(path)}'));
    await _own(File(path), owned);
    return store.upsert(
      localId: 'manual:$hash',
      contentHash: hash,
      platform: Platform.isIOS ? 'ios' : 'android',
      sourceType: AssetSourceType.manualFile,
      sourcePath: owned.path,
      isVideo: _isVideoPath(path),
      isGif: isGifPath(path),
      // Not a date from the file name: a hidden photo's object is named
      // with its decoy's date.
      createdAt: createdAt ?? await fileCaptureDate(owned) ?? fallbackDate,
      passcodeHash: passcodeHash,
      isHidden: isHidden,
      isArchived: isArchived,
    );
  }
}

/// Puts a whole copy of [source] at [owned]. Copied to `.part` and renamed,
/// so a kill mid-copy never leaves a short file under the final name; one
/// already there at the wrong size (from before this) is copied again
/// (05#10).
Future<void> _own(File source, File owned) async {
  final size = await source.length();
  if (await owned.exists() && await owned.length() == size) return;
  final part = File('${owned.path}.part');
  await source.copy(part.path);
  if (await part.length() != size) {
    await part.delete();
    throw FileSystemException('Copy came out short', owned.path);
  }
  await part.rename(owned.path);
}

/// The camera's date from [file]'s own header, or null. Without it an
/// imported photo is dated the day it was imported.
Future<DateTime?> fileCaptureDate(File file) async {
  RandomAccessFile? raf;
  try {
    final opened = raf = await file.open();
    final size = await opened.length();
    Future<Uint8List?> read(int start, int end) async {
      await opened.setPosition(start);
      return opened.read(end - start);
    }

    if (_isVideoPath(file.path)) return await videoCaptureDate(read, size);
    final head = await read(0, size < 256 * 1024 ? size : 256 * 1024);
    return head == null ? null : stillCaptureDate(head);
  } catch (_) {
    return null;
  } finally {
    await raf?.close();
  }
}

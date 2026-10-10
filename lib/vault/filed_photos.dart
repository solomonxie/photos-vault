import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../photos/file_hash.dart' as file_hash;
import '../photos/photo_library_service.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'album_index.dart';
import 'bucket.dart';
import 'carrier.dart';
import 'cipher.dart';
import 'gallery.dart' show siblingCarrierKeys;
import 'keys.dart';
import 'object_key.dart';
import 'store.dart';

/// Turns photos older builds *filed* — plain file deleted, sometimes the row
/// too, only the encrypted carrier left — back into ordinary hidden photos:
/// a plain file on this phone and a row, so they show and open like every
/// other photo. The carrier in the bucket stays as their backup.
class FiledPhotos {
  FiledPhotos({
    required this.records,
    VaultStore? store,
    VaultBucket? bucket,
    VaultCipher? cipher,
    Future<Directory> Function()? directory,
    Future<String> Function(String path)? hashFile,
  }) : _store = store ?? VaultStore(),
       _bucket = bucket ?? VaultBucket(),
       _cipher = cipher ?? PlatformCipher(),
       _directory = directory ?? getApplicationSupportDirectory,
       _hashFile = hashFile ?? file_hash.hashFile;

  final AssetRecordStore records;
  final VaultStore _store;
  final VaultBucket _bucket;
  final VaultCipher _cipher;
  final Future<Directory> Function() _directory;
  final Future<String> Function(String path) _hashFile;

  /// A row whose plain file is gone: decrypted back from this phone's
  /// carrier. True when the row has a file again.
  Future<bool> restoreRow(AlbumKeys keys, AssetRecord record) async {
    final key = vaultCarrierKey(record, keys.carrier);
    final opened = await _openLocal(keys, key);
    if (opened == null) return false;
    final path = await _write(key, opened);
    await records.setSourcePath(record.localId, path);
    if (record.isLivePhoto) {
      await _restoreMotion(
        keys,
        vaultLiveCarrierKey(record, keys.carrier),
        path,
      );
    }
    return true;
  }

  /// An index entry with no row: given one, from this phone's carrier or —
  /// with [download] — the bucket's, once. Null when neither has it, or it
  /// was never sent (that carrier is the only copy, and stays one).
  Future<AssetRecord?> adopt(
    AlbumKeys keys,
    String passcodeHash,
    IndexEntry entry, {
    bool download = false,
  }) async {
    final key = entry.objectKey;
    if (await _store.isUnsent(keys, key)) return null;
    var opened = await _openLocal(keys, key);
    if (opened == null && download) {
      final bytes = await _bucket.object(key);
      if (bytes != null) opened = await _openBytes(keys, bytes);
    }
    if (opened == null) return null;
    final path = await _write(key, opened);
    // An entry filed before the index recorded motion says null, not
    // false: its `.mov` may be there, and is looked for rather than lost.
    final motionKey = _motionKeyOf(key);
    final moves =
        motionKey != null &&
        !entry.isVideo &&
        entry.hasMotion != false &&
        await _restoreMotion(keys, motionKey, path, download: download);
    final localId = 'manual:vault-${p.basenameWithoutExtension(key)}';
    await records.upsert(
      localId: localId,
      contentHash: await _hashFile(path),
      platform: Platform.operatingSystem,
      sourceType: AssetSourceType.manualFile,
      sourcePath: path,
      isVideo: entry.isVideo,
      isLivePhoto: moves || entry.hasMotion == true,
      createdAt: entry.takenAt,
      width: entry.width == 0 ? null : entry.width,
      height: entry.height == 0 ? null : entry.height,
    );
    await records.setPasscodeHash(localId, passcodeHash);
    // Already in the bucket: that carrier is this photo's backup.
    await records.updateDerivative(
      localId,
      DerivativeKind.original,
      DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
    );
    if (moves) {
      await records.updateDerivative(
        localId,
        DerivativeKind.livePhoto,
        DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: motionKey,
        ),
      );
    }
    // The plain files are the copy on this phone now; a second, encrypted
    // one would only double the space. A `.mov` carrier goes only once its
    // plain file is written. The bucket keeps both.
    await _store.removeAll(keys, [key, if (moves) motionKey]);
    return records.getByLocalId(localId);
  }

  static const _motionCheckedKey = 'hidden_motion_checked_v1';

  /// Rows an earlier build adopted as stills because their index entry
  /// never said they move: each `.mov` sought once beside its original in
  /// the bucket and put back. True when any moves again.
  Future<bool> repairMotion(AlbumKeys keys, List<AssetRecord> rows) async {
    final checked = <String>{
      ...((jsonDecode(
        await records.getAppState(_motionCheckedKey) ?? '[]',
      ) as List).cast<String>()),
    };
    var changed = false;
    var learned = false;
    for (final record in rows) {
      if (!record.localId.startsWith('manual:vault-') ||
          record.isVideo ||
          record.isLivePhoto ||
          checked.contains(record.localId)) {
        continue;
      }
      final moves = await _repairOne(keys, record);
      if (moves == null) continue;
      checked.add(record.localId);
      learned = true;
      changed |= moves;
    }
    if (learned) {
      await records.setAppState(_motionCheckedKey, jsonEncode([...checked]));
    }
    return changed;
  }

  /// Null when the bucket couldn't be asked: tried again next time.
  Future<bool?> _repairOne(AlbumKeys keys, AssetRecord record) async {
    final path = record.sourcePath;
    final original = record.stateOf(DerivativeKind.original).destinationKey;
    if (path == null || original == null) return false;
    final at = original.indexOf('originals/');
    final motionKey = _motionKeyOf(
      at == -1 ? original : original.substring(at),
    );
    if (motionKey == null) return false;
    var opened = await _openLocal(keys, motionKey);
    if (opened == null) {
      final fetched = await _bucket.fetch(motionKey);
      final bytes = fetched.bytes;
      if (bytes == null) return fetched.absent ? false : null;
      opened = await _openBytes(keys, bytes);
      if (opened == null) return false;
    }
    await File(PhotoLibraryService.heldLiveVideoPath(path))
        .writeAsBytes(opened.original, flush: true);
    await records.setLivePhoto(record.localId, true);
    await records.updateDerivative(
      record.localId,
      DerivativeKind.livePhoto,
      DerivativeState(status: UploadStatus.uploaded, destinationKey: motionKey),
    );
    await _store.removeAll(keys, [motionKey]);
    return true;
  }

  static String? _motionKeyOf(String key) =>
      siblingCarrierKeys(key).where((k) => k != key).firstOrNull;

  Future<bool> _restoreMotion(
    AlbumKeys keys,
    String key,
    String stillPath, {
    bool download = false,
  }) async {
    var opened = await _openLocal(keys, key);
    if (opened == null && download) {
      final bytes = await _bucket.object(key);
      if (bytes != null) opened = await _openBytes(keys, bytes);
    }
    if (opened == null) return false;
    await File(PhotoLibraryService.heldLiveVideoPath(stillPath))
        .writeAsBytes(opened.original, flush: true);
    return true;
  }

  Future<OpenedCarrier?> _openLocal(AlbumKeys keys, String key) async {
    final file = await _store.carrierFile(keys, key);
    if (!await file.exists()) return null;
    final cipher = _cipher;
    final carrierKeys = keys.carrier;
    final path = file.path;
    // MAC and decryption of the whole file: off the UI isolate.
    return Isolate.run(() async {
      final payload = payloadOf(await File(path).readAsBytes());
      if (payload == null) return null;
      return openCarrier(cipher: cipher, keys: carrierKeys, payload: payload);
    });
  }

  Future<OpenedCarrier?> _openBytes(AlbumKeys keys, Uint8List bytes) {
    final cipher = _cipher;
    final carrierKeys = keys.carrier;
    return Isolate.run(() {
      final payload = payloadOf(bytes);
      if (payload == null) return null;
      return openCarrier(cipher: cipher, keys: carrierKeys, payload: payload);
    });
  }

  /// Beside the files hiding copies out of Photos.
  Future<String> _write(String key, OpenedCarrier opened) async {
    final dir = await _directory();
    final path = p.join(
      dir.path,
      'hidden_${p.basenameWithoutExtension(key)}.${opened.extension}',
    );
    await File(path).writeAsBytes(opened.original, flush: true);
    return path;
  }
}

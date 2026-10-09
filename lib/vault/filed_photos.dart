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
    final localId = 'manual:vault-${p.basenameWithoutExtension(key)}';
    await records.upsert(
      localId: localId,
      contentHash: await _hashFile(path),
      platform: Platform.operatingSystem,
      sourceType: AssetSourceType.manualFile,
      sourcePath: path,
      isVideo: entry.isVideo,
      isLivePhoto: entry.hasMotion == true,
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
    if (entry.hasMotion == true) {
      final motionKey = siblingCarrierKeys(key)
          .firstWhere((k) => k != key, orElse: () => '');
      if (motionKey.isNotEmpty &&
          await _restoreMotion(keys, motionKey, path, download: download)) {
        await records.updateDerivative(
          localId,
          DerivativeKind.livePhoto,
          DerivativeState(
            status: UploadStatus.uploaded,
            destinationKey: motionKey,
          ),
        );
      }
    }
    // The plain file is the copy on this phone now; a second, encrypted one
    // would only double the space. The bucket keeps the carrier.
    await _store.removeAll(keys, siblingCarrierKeys(key));
    return records.getByLocalId(localId);
  }

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

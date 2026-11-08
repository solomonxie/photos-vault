import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../photos/file_hash.dart' as file_hash;
import '../photos/photo_library_service.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/s3_uploader.dart';
import 'album_index.dart';
import 'bucket.dart';
import 'carrier.dart';
import 'carrier_stream.dart';
import 'cipher.dart';
import 'gallery.dart' show payloadOfPrefix, siblingCarrierKeys;
import 'keys.dart';
import 'object_key.dart';
import 'plain_files.dart';
import 'retired_carriers.dart';
import 'store.dart';

/// What [FiledPhotos.carry] did with a photo only the bucket has.
enum CarryOutcome {
  /// It has a row in the other folder now; its carrier here is retired.
  moved,

  /// Every bucket answered 404: nothing to carry, and it no longer counts.
  gone,

  /// Not fetched or not opened: it stays where it was, counted as before.
  failed,
}

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
    final path = await _openLocal(keys, key, await _plainPath(key));
    if (path == null) return false;
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
    final localId = 'manual:vault-${p.basenameWithoutExtension(key)}';
    // Un-hidden (or in another album) already: never pulled back in here.
    final existing = await records.getByLocalId(localId);
    if (existing != null && existing.passcodeHash != passcodeHash) return null;
    final to = await _plainPath(key);
    var path = await _openLocal(keys, key, to);
    if (path == null && download) path = await _openRemote(keys, key, to);
    if (path == null) return null;
    // An entry filed before the index recorded motion says null, not
    // false: its `.mov` may be there, and is looked for rather than lost.
    final motionKey = _motionKeyOf(key);
    final moves =
        motionKey != null &&
        !entry.isVideo &&
        entry.hasMotion != false &&
        await _restoreMotion(keys, motionKey, path, download: download);
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
      // Hidden from its first write.
      passcodeHash: passcodeHash,
    );
    // Backed up only where every bucket answers with the carrier now: one
    // the bucket lost has to go up again, not be taken on trust.
    final stillUp = await _bucket.isEverywhere(key);
    final motionUp =
        moves &&
        !await _store.isUnsent(keys, motionKey) &&
        await _bucket.isEverywhere(motionKey);
    await records.updateDerivative(
      localId,
      DerivativeKind.original,
      stillUp
          ? DerivativeState(status: UploadStatus.uploaded, destinationKey: key)
          : const DerivativeState(),
    );
    if (moves) {
      await records.updateDerivative(
        localId,
        DerivativeKind.livePhoto,
        motionUp
            ? DerivativeState(
                status: UploadStatus.uploaded,
                destinationKey: motionKey,
              )
            : const DerivativeState(),
      );
    }
    // The plain files are the copy on this phone now; a second, encrypted
    // one would only double the space. A carrier goes only once every
    // bucket is seen to hold it.
    await _store.removeAll(keys, [if (stillUp) key, if (motionUp) motionKey]);
    return records.getByLocalId(localId);
  }

  /// The row a carry of [objectKey] makes: the same whichever phone or
  /// time zone works it out, so a second carry finds the first's.
  static String carriedId(String objectKey) =>
      'manual:${sha256.convert(utf8.encode('carried|${carrierIdentity(objectKey)}'))}';

  /// [entry], a photo only the bucket holds under [from], decrypted to a
  /// plain file with a row of its own in the folder tagged [toTag]. The row
  /// starts with nothing uploaded, so the backup encrypts it under that
  /// folder's key and sends it as a new object. Additive: nothing in any
  /// bucket is deleted or overwritten; the old carrier is only retired
  /// ([RetiredCarriers]) so the source stops counting it. A download or
  /// open that fails leaves it in the source, untouched.
  Future<CarryOutcome> carry(
    AlbumKeys from,
    IndexEntry entry,
    String toTag,
  ) async {
    final key = entry.objectKey;
    final localId = carriedId(key);
    final motionKey = entry.isVideo || entry.hasMotion == false
        ? null
        : _motionKeyOf(key);
    if (await records.getByLocalId(localId) != null) {
      await RetiredCarriers(records).add([key, ?motionKey]);
      return CarryOutcome.moved;
    }
    final still = await _fetchOpen(from, key, _plainIn(await _dir(), localId));
    if (still.miss case final miss?) {
      if (miss == CarryOutcome.gone) await RetiredCarriers(records).add([key]);
      return miss;
    }
    final path = still.path!;
    var moves = false;
    if (motionKey != null) {
      final motion = await _fetchOpen(
        from,
        motionKey,
        _exactly(PhotoLibraryService.heldLiveVideoPath(path)),
      );
      if (motion.miss == CarryOutcome.failed) {
        await _drop(path);
        return CarryOutcome.failed;
      }
      // Gone from every bucket: the still is all there is to carry.
      moves = motion.miss == null;
    }
    final meta = still.meta;
    try {
      await records.upsert(
        localId: localId,
        contentHash: await _hashFile(path),
        platform: Platform.operatingSystem,
        sourceType: AssetSourceType.manualFile,
        sourcePath: path,
        isVideo: meta?.isVideo ?? entry.isVideo,
        isLivePhoto: moves,
        createdAt: meta?.takenAt ?? entry.takenAt,
        width: _dimension(meta?.width ?? entry.width),
        height: _dimension(meta?.height ?? entry.height),
        // Hidden from its first write.
        passcodeHash: toTag,
      );
    } catch (_) {
      await _drop(path);
      if (moves) await _drop(PhotoLibraryService.heldLiveVideoPath(path));
      return CarryOutcome.failed;
    }
    await RetiredCarriers(records).add([key, if (moves) ?motionKey]);
    return CarryOutcome.moved;
  }

  static int? _dimension(int value) => value == 0 ? null : value;

  static Future<void> _drop(String path) async {
    try {
      await File(path).delete();
    } catch (_) {}
  }

  /// [key]'s carrier — this phone's, else the bucket's on the background
  /// transfer — opened under [keys] to [to], off the UI isolate. [miss]
  /// says why there is no path.
  Future<({String? path, CarrierMeta? meta, CarryOutcome? miss})> _fetchOpen(
    AlbumKeys keys,
    String key,
    String Function(String extension) to,
  ) async {
    final local = await _store.carrierFile(keys, key);
    if (await local.exists()) {
      final opened = await _openWithMeta(keys, local.path, to);
      return (
        path: opened.path,
        meta: opened.meta,
        miss: opened.path == null ? CarryOutcome.failed : null,
      );
    }
    final fetched = await _bucket.fetchFile(key);
    final file = fetched.file;
    if (file == null) {
      return (
        path: null,
        meta: null,
        miss: fetched.absent ? CarryOutcome.gone : CarryOutcome.failed,
      );
    }
    try {
      final opened = await _openWithMeta(keys, file.path, to);
      return (
        path: opened.path,
        meta: opened.meta,
        miss: opened.path == null ? CarryOutcome.failed : null,
      );
    } finally {
      await dropScratch(file);
    }
  }

  /// [_openPath], with the carrier's own date and size from its first
  /// bytes where it carries them.
  Future<({String? path, CarrierMeta? meta})> _openWithMeta(
    AlbumKeys keys,
    String path,
    String Function(String extension) to,
  ) {
    final cipher = _cipher;
    final carrierKeys = keys.carrier;
    return Isolate.run(() {
      CarrierMeta? meta;
      try {
        final file = File(path).openSync();
        try {
          final payload = payloadOfPrefix(file.readSync(thumbnailPrefixBytes));
          if (payload != null) {
            meta = openMeta(
              cipher: cipher,
              keys: carrierKeys,
              payloadPrefix: payload,
            );
          }
        } finally {
          file.closeSync();
        }
      } catch (_) {}
      String? wrote;
      final opened = openCarrierFile(
        cipher: cipher,
        keys: carrierKeys,
        path: path,
        toPath: (extension) => wrote = to(extension),
      );
      return (path: opened == null ? null : wrote, meta: meta);
    });
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
    final to = _exactly(PhotoLibraryService.heldLiveVideoPath(path));
    if (await _openLocal(keys, motionKey, to) == null) {
      final fetched = await _bucket.fetchFile(motionKey);
      final file = fetched.file;
      if (file == null) return fetched.absent ? false : null;
      final opened = await _openPath(keys, file.path, to);
      await dropScratch(file);
      if (opened == null) return false;
    }
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
    final to = _exactly(PhotoLibraryService.heldLiveVideoPath(stillPath));
    var opened = await _openLocal(keys, key, to);
    if (opened == null && download) opened = await _openRemote(keys, key, to);
    return opened != null;
  }

  /// The paths below name the plain file for the carrier's extension.
  static String Function(String) _exactly(String path) =>
      (_) => path;

  /// This phone's carrier, decrypted to [to]. The path written, or null.
  Future<String?> _openLocal(
    AlbumKeys keys,
    String key,
    String Function(String extension) to,
  ) async {
    final file = await _store.carrierFile(keys, key);
    if (!await file.exists()) return null;
    return _openPath(keys, file.path, to);
  }

  /// The bucket's copy, by way of a scratch file dropped once opened.
  Future<String?> _openRemote(
    AlbumKeys keys,
    String key,
    String Function(String extension) to,
  ) async {
    final file = await _bucket.objectFile(key);
    if (file == null) return null;
    try {
      return await _openPath(keys, file.path, to);
    } finally {
      await dropScratch(file);
    }
  }

  /// MAC and decryption streamed from file to file, off the UI isolate
  /// (BG-13): a hidden video never sits whole in memory.
  Future<String?> _openPath(
    AlbumKeys keys,
    String path,
    String Function(String extension) to,
  ) {
    final cipher = _cipher;
    final carrierKeys = keys.carrier;
    return Isolate.run(() {
      String? wrote;
      final opened = openCarrierFile(
        cipher: cipher,
        keys: carrierKeys,
        path: path,
        toPath: (extension) => wrote = to(extension),
      );
      return opened == null ? null : wrote;
    });
  }

  /// Beside the files hiding copies out of Photos: `vault/plain/`, out of
  /// the device backup, named after nothing. The same name for the same
  /// carrier, so a second open overwrites rather than adds.
  Future<String Function(String extension)> _plainPath(String key) async =>
      _plainIn(await _dir(), 'manual:vault-${p.basenameWithoutExtension(key)}');

  Future<String> _dir() async =>
      (await PlainFiles(store: records, directory: _directory).dir()).path;

  // Static: the closure goes to an isolate, so it must not hold `this`.
  static String Function(String extension) _plainIn(
    String dir,
    String localId,
  ) =>
      (extension) =>
          p.join(dir, PlainFiles.neutralName(localId, '.$extension'));
}

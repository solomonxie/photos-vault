import 'dart:async';
import 'dart:io';

import '../photos/photo_library_service.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'album_index.dart';
import 'bucket.dart';
import 'keys.dart';
import 'object_key.dart';
import 'store.dart';

/// A hidden photo's carrier is filed, so the plaintext stops existing.
///
/// **The local carrier is what this waits for, not the upload.** The
/// carrier in `VaultStore` is the copy of the photo — encrypted, disguised,
/// durable, out of the device backup — so once it is written the phone has
/// the photo and the plaintext original is a duplicate that happens to be
/// readable. A bucket is the second copy; with none configured, or none
/// reachable, hiding still completes and the album still opens.
///
/// The row matters as much as the file. It carries the photo's date,
/// name, description, place, people — and the count of rows is the answer
/// to the one question the gate exists not to answer. All of it goes into
/// the album's own index instead, which is encrypted and padded.
class HiddenFiling {
  HiddenFiling({
    required this.records,
    required this.vaultStore,
    required this.bucket,
    required this.keysFor,
    required this.passphrases,
    required this.removeThumbnail,
  });

  final AssetRecordStore records;
  final VaultStore vaultStore;
  final VaultBucket bucket;

  /// `VaultKeys.ringKeysFor`: null while the album is locked.
  final AlbumKeys? Function(String passcodeHash) keysFor;
  final Future<List<PassphraseEntry>> Function() passphrases;
  final Future<void> Function(AssetRecord record) removeThumbnail;

  /// True when [record] was filed and its row and plaintext are gone.
  Future<bool> file(AssetRecord record, {required String name}) async {
    final hash = record.passcodeHash;
    if (hash == null) return false;
    // Still in Photos (the OS delete prompt was declined): deleting the row
    // now would let the next scan re-add it as an ordinary photo.
    if (record.libraryId != null) return false;
    final keys = keysFor(hash);
    if (keys == null) return false;

    // The key the coordinator filed the carrier under — worked out from the
    // record, because with no bucket there is no destination key to read.
    final key = vaultCarrierKey(record);
    if (!await vaultStore.hasCarrier(keys, key)) return false;
    // Both halves, for a Live Photo. Settling on the still alone would
    // delete the plaintext while the motion and the sound were still only in
    // the photo library this has just taken the photo out of.
    if (record.isLivePhoto &&
        !await vaultStore.hasCarrier(keys, vaultLiveCarrierKey(record))) {
      return false;
    }

    final album = await bucket.readAlbum(keys);
    final entry = IndexEntry(
      objectKey: key,
      takenAt: record.createdAt,
      width: record.width ?? 0,
      height: record.height ?? 0,
      isVideo: record.countsAsVideo,
      name: name,
      hasMotion: record.isLivePhoto,
    );
    final entries = [
      for (final e in album.entries)
        if (e.objectKey != key) e,
      entry,
    ];
    // Local index first, and it is the one that has to land: it is what
    // lists the album on a phone with no signal, and the row about to be
    // deleted is the only other place this photo is described.
    final index = await bucket.encodeAlbum(
      keys: keys,
      entries: entries,
      passphrases: await passphrases(),
    );
    if (index == null) return false;
    // Filed before any bucket held it: marked, so it goes up once one does.
    if (record.stateOf(DerivativeKind.original).status !=
        UploadStatus.uploaded) {
      await vaultStore.setUnsent(keys, key, true);
    }
    if (record.isLivePhoto &&
        record.stateOf(DerivativeKind.livePhoto).status !=
            UploadStatus.uploaded) {
      await vaultStore.setUnsent(keys, vaultLiveCarrierKey(record), true);
    }
    await bucket.keepIndex(index);
    // Best-effort, and deliberately after: a bucket that is unreachable
    // today gets it on the next index read, which pushes an unpublished
    // local index before trusting the bucket's.
    unawaited(bucket.pushIndex(index));

    await removeThumbnail(record);
    final path = record.sourcePath;
    if (path != null) {
      for (final file in [path, PhotoLibraryService.heldLiveVideoPath(path)]) {
        try {
          await File(file).delete();
        } catch (_) {
          // Already gone.
        }
      }
    }
    await records.remove(record.localId);
    return true;
  }
}

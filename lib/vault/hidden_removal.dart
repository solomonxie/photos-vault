import 'dart:async';
import 'dart:io';

import '../photos/photo_library_service.dart';
import '../photos/thumbnail_cache.dart';
import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/pending_deletes.dart';
import 'album_index.dart';
import 'bucket.dart';
import 'keys.dart';
import 'object_key.dart';
import 'store.dart';

/// Deleting a hidden photo, for good.
///
/// Not the library's delete: that one bins the photo into Recently Deleted,
/// which opens without a passcode — a hidden photo there is a hidden photo
/// shown to anyone holding the phone. So this is permanent, and the screen
/// says so before it runs.
///
/// Order is index first, then this phone's files, then the bucket. The
/// index is what lists the album; once a photo is out of it nothing draws
/// it, and a crash after that point leaves an orphaned encrypted file at
/// worst — never a listed photo whose bytes are gone. Bucket objects go
/// through [PendingDeletes], so a delete made offline still lands.
class HiddenRemoval {
  HiddenRemoval({
    required this.store,
    BackupTargetsStore? targetsStore,
    VaultStore? vaultStore,
    VaultBucket? bucket,
    PendingDeletes? pendingDeletes,
    ThumbnailCache? thumbnails,
  }) : _targets = targetsStore ?? BackupTargetsStore(),
       _vaultStore = vaultStore ?? VaultStore(),
       _pendingDeletes = pendingDeletes ?? PendingDeletes(store: store),
       _thumbnails = thumbnails ?? ThumbnailCache(store: store),
       _bucket =
           bucket ??
           VaultBucket(
             targetsStore: targetsStore ?? BackupTargetsStore(),
             store: vaultStore,
           );

  final AssetRecordStore store;
  final BackupTargetsStore _targets;
  final VaultStore _vaultStore;
  final VaultBucket _bucket;
  final PendingDeletes _pendingDeletes;
  final ThumbnailCache _thumbnails;

  /// Removes [records] (hidden, not yet filed) and [entries] (filed into the
  /// album index) from [keys]' album. [passphrases] are written back with
  /// the index unchanged.
  /// False when nothing was deleted because the index couldn't be
  /// rewritten.
  Future<bool> delete({
    required AlbumKeys? keys,
    List<AssetRecord> records = const [],
    List<IndexEntry> entries = const [],
    List<PassphraseEntry> passphrases = const [],
  }) async {
    final filedKeys = <String>{
      for (final e in entries) ...siblingKeys(e.objectKey),
    };
    final recordCarrierKeys = <String>{
      if (keys != null)
        for (final r in records) ...[
          vaultCarrierKey(r, keys.carrier),
          if (r.isLivePhoto) vaultLiveCarrierKey(r, keys.carrier),
        ],
    };

    // What a bucket actually holds: filed carriers that went up, and a
    // record's uploads by their recorded keys. A photo never backed up has
    // nothing remote, so nothing is asked of the network for it. Read
    // before the local files go: removing them clears the unsent marks.
    final sentKeys = <String>{};
    if (keys != null) {
      for (final e in entries) {
        if (!await _vaultStore.isUnsent(keys, e.objectKey)) {
          sentKeys.addAll(siblingKeys(e.objectKey));
        }
      }
    }

    if (keys != null) {
      // Only a filed photo is listed in the index. An unfiled record was
      // never in it, so its delete never reads or writes the index.
      if (filedKeys.isNotEmpty &&
          !await _unlist(keys, filedKeys, passphrases)) {
        return false;
      }
      await _vaultStore.removeAll(keys, {...filedKeys, ...recordCarrierKeys});
    }

    for (final record in records) {
      final path = record.sourcePath;
      if (path != null) {
        for (final file in [
          path,
          PhotoLibraryService.heldLiveVideoPath(path),
        ]) {
          try {
            await File(file).delete();
          } catch (_) {
            // Already gone.
          }
        }
      }
      await _thumbnails.remove(record);
      await store.remove(record.localId);
    }

    final objectKeys = <String>{
      for (final r in records)
        for (final kind in DerivativeKind.values)
          ?r.stateOf(kind).destinationKey,
    };
    final targets = await _loadTargets();
    final tasks = [
      for (final target in targets) ...[
        for (final key in objectKeys)
          PendingDelete(objectKey: key, targetId: target.id),
        for (final key in sentKeys)
          PendingDelete(
            objectKey: VaultBucket.resolveKey(target, key),
            targetId: target.id,
          ),
      ],
    ];
    if (tasks.isEmpty) return true;
    await _pendingDeletes.add(tasks);
    // Queued is enough to answer: the photo is already gone from the
    // album and this phone, and a screen waiting on one round trip per
    // object looked like a delete that did nothing.
    unawaited(_drain(targets));
    return true;
  }

  Future<void> _drain(List<S3BackupTarget> targets) async {
    try {
      await _pendingDeletes.drain(targets);
    } catch (_) {
      // Queued; the next sync retries.
    }
  }

  /// Un-hiding filed photos, once Photos holds each again: [plainIds] maps
  /// an entry's object key to the `localId` of its copy in Photos. Index
  /// first, then this phone's carriers. The buckets' carriers wait in
  /// [DeferredDeletes] until that copy has reached every bucket.
  Future<bool> release({
    required AlbumKeys keys,
    required Map<String, String> plainIds,
    List<PassphraseEntry> passphrases = const [],
  }) async {
    if (plainIds.isEmpty) return true;
    final carrierKeys = <String>{
      for (final key in plainIds.keys) ...siblingKeys(key),
    };
    if (!await _unlist(keys, carrierKeys, passphrases)) return false;
    await _vaultStore.removeAll(keys, carrierKeys);
    final targets = await _loadTargets();
    final deferred = DeferredDeletes(store: store, pending: _pendingDeletes);
    for (final MapEntry(key: objectKey, value: localId) in plainIds.entries) {
      await deferred.add(localId, [
        for (final target in targets)
          for (final key in siblingKeys(objectKey))
            PendingDelete(
              objectKey: VaultBucket.resolveKey(target, key),
              targetId: target.id,
            ),
      ]);
    }
    return true;
  }

  Future<bool> _unlist(
    AlbumKeys keys,
    Set<String> carrierKeys,
    List<PassphraseEntry> passphrases,
  ) async {
    try {
      final album = await _bucket.readAlbum(keys);
      final kept = [
        for (final e in album.entries)
          if (!carrierKeys.contains(e.objectKey)) e,
      ];
      if (kept.length == album.entries.length) return true;
      final index = await _bucket.encodeAlbum(
        keys: keys,
        entries: kept,
        passphrases: passphrases.isEmpty ? album.passphrases : passphrases,
      );
      if (index == null) return false;
      // Landed here and marked unpublished; the buckets get it in the
      // background, and every read offers it again until they have.
      await _bucket.keepIndex(index);
      unawaited(_bucket.pushIndex(index));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A carrier and its Live Photo twin share a name and differ by
  /// extension. The index does not say which stills have a twin, so both
  /// are named; a missing one is a 404, which counts as gone.
  static List<String> siblingKeys(String objectKey) {
    final dot = objectKey.lastIndexOf('.');
    if (dot == -1) return [objectKey];
    final base = objectKey.substring(0, dot);
    return {objectKey, '$base.jpg', '$base.mov'}.toList();
  }

  Future<List<S3BackupTarget>> _loadTargets() async {
    try {
      return await _targets.loadAll();
    } catch (_) {
      return const [];
    }
  }
}

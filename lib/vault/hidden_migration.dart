import 'dart:io';

import '../settings/backup_targets_store.dart';
import '../upload/bucket_ops.dart';
import 'album_index.dart';
import 'bucket.dart';
import 'keys.dart';
import 'object_key.dart';
import 'store.dart';

/// Gives an album's carriers protocol names, once, while the album is open.
///
/// The same steps as an ordinary photo's migration: copy to the new name,
/// point the index at it, and only then delete the old. Nothing is deleted
/// before the index that lists the new name has landed, so an interruption
/// leaves both names and loses neither.
class HiddenMigration {
  HiddenMigration({
    required this.targetsStore,
    required this.vaultStore,
    required this.bucket,
    required this.passphrases,
    BucketOps? ops,
  }) : _ops = ops ?? BucketOps();

  final BackupTargetsStore targetsStore;
  final VaultStore vaultStore;
  final VaultBucket bucket;
  final Future<List<PassphraseEntry>> Function() passphrases;
  final BucketOps _ops;

  /// How many carriers were renamed.
  Future<int> run(AlbumKeys keys, {int limit = 20}) async {
    final album = await bucket.readAlbum(keys);
    final stale = [
      for (final e in album.entries)
        if (!fitsProtocol(e.objectKey.split('/').last)) e,
    ].take(limit).toList();
    if (stale.isEmpty) return 0;

    final targets = await targetsStore.loadAll();
    final moved = <IndexEntry, String>{};
    final oldKeys = <String>[];
    for (final entry in stale) {
      final newKey = _newKeyFor(keys, entry.objectKey);
      final pairs = _siblingPairs(entry.objectKey, newKey);
      var copied = true;
      for (final (from, to) in pairs) {
        final local = await _copyLocal(keys, from, to);
        var remote = false;
        if (!await vaultStore.isUnsent(keys, from)) {
          for (final target in targets) {
            final size = await _ops.sizeOf(
              target,
              VaultBucket.resolveKey(target, from),
            );
            if (size == null) continue;
            remote = true;
            final toKey = VaultBucket.resolveKey(target, to);
            if (await _ops.sizeOf(target, toKey) == size) continue;
            final ok = await _ops.copy(
              target: target,
              from: VaultBucket.resolveKey(target, from),
              to: toKey,
              expectedSize: size,
            );
            if (!ok) copied = false;
          }
        }
        // The still must be held somewhere; a missing motion half is
        // just a photo that was never live.
        if (from == entry.objectKey && !local && !remote) copied = false;
      }
      if (!copied) continue;
      moved[entry] = newKey;
      oldKeys.addAll(pairs.map((p) => p.$1));
    }
    if (moved.isEmpty) return 0;

    final entries = [
      for (final e in album.entries)
        if (moved.containsKey(e))
          IndexEntry(
            objectKey: moved[e]!,
            takenAt: e.takenAt,
            width: e.width,
            height: e.height,
            isVideo: e.isVideo,
            name: e.name,
            hasMotion: e.hasMotion,
          )
        else
          e,
    ];
    final written = await bucket.writeAlbum(
      keys: keys,
      entries: entries,
      passphrases: await passphrases(),
    );
    if (!written) return 0;

    await vaultStore.removeAll(keys, oldKeys);
    for (final target in targets) {
      for (final key in oldKeys) {
        await _ops.delete(target, VaultBucket.resolveKey(target, key));
      }
    }
    return moved.length;
  }

  String _newKeyFor(AlbumKeys keys, String oldKey) {
    final dot = oldKey.lastIndexOf('.');
    final ext = dot == -1 ? '' : oldKey.substring(dot);
    return vaultObjectKey(
      'originals',
      '${hiddenBaseNameFor(keys.carrier, oldKey)}$ext',
    );
  }

  /// A Live Photo's still and its motion half move together, under one
  /// new base name.
  List<(String, String)> _siblingPairs(String oldKey, String newKey) {
    final oldDot = oldKey.lastIndexOf('.');
    final newDot = newKey.lastIndexOf('.');
    if (oldDot == -1 || newDot == -1) return [(oldKey, newKey)];
    final pairs = <(String, String)>[(oldKey, newKey)];
    final motionOld = '${oldKey.substring(0, oldDot)}.mov';
    if (motionOld != oldKey) {
      pairs.add((motionOld, '${newKey.substring(0, newDot)}.mov'));
    }
    return pairs;
  }

  Future<bool> _copyLocal(AlbumKeys keys, String from, String to) async {
    if (!await vaultStore.hasCarrier(keys, from)) return false;
    final file = await vaultStore.carrierFile(keys, from);
    final stored = await vaultStore.putCarrier(keys, to, File(file.path));
    if (stored == null) return false;
    if (await vaultStore.isUnsent(keys, from)) {
      await vaultStore.setUnsent(keys, to, true);
    }
    return true;
  }
}

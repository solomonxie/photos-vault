import '../settings/backup_targets_store.dart';
import '../storage/asset_record_store.dart';
import '../upload/bucket_ops.dart';
import 'album_index.dart';
import 'bucket.dart';
import 'carrier.dart';
import 'carrier_probe.dart';
import 'cipher.dart';
import 'keys.dart';
import 'object_key.dart';

/// Finds carriers in the bucket that belong to this album but are missing
/// from its index, and lists them.
///
/// The check is local: every `originals/` name in `bucket_object` is held
/// against the album's key, which costs no request. Only a match is read,
/// once, for its date and size - a ranged read of the first 64 KB.
class HiddenBucketScan {
  HiddenBucketScan({
    required this.store,
    required this.targetsStore,
    required this.bucket,
    required this.passphrases,
    VaultCipher? cipher,
    BucketOps? ops,
    CarrierProbe? probe,
  }) : _cipher = cipher ?? PlatformCipher(),
       _ops = ops ?? BucketOps(),
       _probe = probe ?? const CarrierProbe();

  final AssetRecordStore store;
  final BackupTargetsStore targetsStore;
  final VaultBucket bucket;
  final Future<List<PassphraseEntry>> Function() passphrases;
  final VaultCipher _cipher;
  final BucketOps _ops;
  final CarrierProbe _probe;

  /// How many carriers were added to [keys]' album.
  Future<int> run(AlbumKeys keys) async {
    final album = await bucket.readAlbum(keys);
    final known = <String>{
      for (final e in album.entries) ...siblingCarrierKeysOf(e.objectKey),
    };
    final macKey = keys.carrier.macKey;
    final targets = {for (final t in await targetsStore.loadAll()) t.id: t};

    final mine = [
      for (final o in await store.listBucketObjects())
        if (o.directory == 'originals' &&
            nameBelongsTo(o.fileName, macKey) &&
            !known.contains(vaultObjectKey('originals', o.fileName)))
          o,
    ];
    final bases = {for (final o in mine) _stemOf(o.fileName)};
    final entries = <IndexEntry>[];
    for (final o in mine) {
      final stem = _stemOf(o.fileName);
      final isMotionHalf =
          o.fileName.endsWith('.mov') &&
          mine.any(
            (m) =>
                m != o &&
                _stemOf(m.fileName) == stem &&
                m.fileName.endsWith('.jpg'),
          );
      if (isMotionHalf) continue;
      final target = targets[o.targetId];
      if (target == null) continue;
      final isVideo =
          o.fileName.endsWith('.mov') || o.fileName.endsWith('.mp4');
      final probed = await _probe.probe(
        read: _ops.rangeReader(target, o.key),
        size: o.size,
        isVideo: isVideo,
      );
      if (probed == null || !headerBelongsTo(probed.header, macKey)) continue;
      final meta = openMeta(
        cipher: _cipher,
        keys: keys.carrier,
        payloadPrefix: probed.payloadPrefix,
      );
      final parsed = parseProtocolName(o.fileName)!;
      entries.add(
        IndexEntry(
          objectKey: vaultObjectKey('originals', o.fileName),
          takenAt:
              meta?.takenAt ?? parseObjectStamp(parsed.stamp) ?? o.lastModified,
          width: meta?.width ?? 0,
          height: meta?.height ?? 0,
          isVideo: meta?.isVideo ?? isVideo,
          hasMotion:
              bases.contains(stem) &&
              mine.any((m) => m != o && _stemOf(m.fileName) == stem),
        ),
      );
    }
    if (entries.isEmpty) return 0;
    final written = await bucket.writeAlbum(
      keys: keys,
      entries: [...album.entries, ...entries],
      passphrases: await passphrases(),
    );
    return written ? entries.length : 0;
  }

  static String _stemOf(String fileName) => fileName.contains('.')
      ? fileName.substring(0, fileName.lastIndexOf('.'))
      : fileName;

  static Iterable<String> siblingCarrierKeysOf(String objectKey) {
    final dot = objectKey.lastIndexOf('.');
    if (dot == -1) return [objectKey];
    return {objectKey, '${objectKey.substring(0, dot)}.mov'};
  }
}

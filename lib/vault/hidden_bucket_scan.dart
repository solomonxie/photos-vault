import '../settings/backup_targets_store.dart';
import '../storage/asset_record_store.dart';
import '../storage/bucket_object.dart';
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
    final entries = await find(
      keys,
      known: {for (final e in album.entries) e.objectKey},
    );
    if (entries.isEmpty) return 0;
    final written = await bucket.writeAlbum(
      keys: keys,
      entries: [...album.entries, ...entries],
      passphrases: await passphrases(),
    );
    return written ? entries.length : 0;
  }

  /// [keys]' carriers in the bucket listing that aren't [known] (object
  /// keys, `originals/<name>`), as entries, written nowhere: an album
  /// opened on another phone shows its photos without the index, which has
  /// room for 32 albums.
  ///
  /// [read]: each is read for its real date and size, one ranged GET apiece
  /// — minutes for a folder of a thousand. Without, the name alone says
  /// it is this album's and when it was taken; the tile's own read fills
  /// in the rest.
  Future<List<IndexEntry>> find(
    AlbumKeys keys, {
    Set<String> known = const {},
    bool read = true,
  }) async {
    // By identity: a row's name worked out in another time zone is still
    // that row's carrier.
    final skip = {
      for (final k in known) ...siblingCarrierKeysOf(k).map(carrierIdentity),
    };
    final macKey = keys.carrier.macKey;
    final targets = {for (final t in await targetsStore.loadAll()) t.id: t};

    final mine = [
      for (final o in await store.listBucketObjects())
        if (o.directory == 'originals' &&
            nameBelongsTo(o.fileName, macKey) &&
            !skip.contains(
              carrierIdentity(vaultObjectKey('originals', o.fileName)),
            ))
          o,
    ];
    final bases = {for (final o in mine) _stemOf(o.fileName)};
    Future<IndexEntry?> one(BucketObject o) async {
      final stem = _stemOf(o.fileName);
      final isMotionHalf =
          o.fileName.endsWith('.mov') &&
          mine.any(
            (m) =>
                m != o &&
                _stemOf(m.fileName) == stem &&
                m.fileName.endsWith('.jpg'),
          );
      if (isMotionHalf) return null;
      final target = targets[o.targetId];
      if (target == null) return null;
      final isVideo =
          o.fileName.endsWith('.mov') || o.fileName.endsWith('.mp4');
      final hasMotion =
          bases.contains(stem) &&
          mine.any((m) => m != o && _stemOf(m.fileName) == stem);
      if (!read) {
        final parsed = parseProtocolName(o.fileName)!;
        return IndexEntry(
          objectKey: vaultObjectKey('originals', o.fileName),
          takenAt: parseObjectStamp(parsed.stamp) ?? o.lastModified,
          width: 0,
          height: 0,
          isVideo: isVideo,
          hasMotion: hasMotion,
        );
      }
      final probed = await _probe.probe(
        read: _ops.rangeReader(target, o.key),
        size: o.size,
        isVideo: isVideo,
      );
      if (probed == null || !headerBelongsTo(probed.header, macKey)) {
        return null;
      }
      final meta = openMeta(
        cipher: _cipher,
        keys: keys.carrier,
        payloadPrefix: probed.payloadPrefix,
      );
      final parsed = parseProtocolName(o.fileName)!;
      return IndexEntry(
        objectKey: vaultObjectKey('originals', o.fileName),
        takenAt:
            meta?.takenAt ?? parseObjectStamp(parsed.stamp) ?? o.lastModified,
        width: meta?.width ?? 0,
        height: meta?.height ?? 0,
        isVideo: meta?.isVideo ?? isVideo,
        hasMotion: hasMotion,
      );
    }

    // Eight reads in flight: one at a time, a folder of a thousand took
    // the better part of ten minutes.
    final entries = <IndexEntry>[];
    for (var i = 0; i < mine.length; i += 8) {
      final part = await Future.wait<IndexEntry?>([
        for (final o in mine.skip(i).take(8)) one(o),
      ]);
      entries.addAll(part.whereType<IndexEntry>());
    }
    return entries;
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

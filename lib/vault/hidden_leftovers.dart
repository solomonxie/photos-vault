import 'dart:isolate';
import 'dart:typed_data';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/pending_deletes.dart';
import 'album_index.dart';
import 'cipher.dart';
import 'hidden_bucket_scan.dart';
import 'keys.dart';
import 'object_key.dart';
import 'retired_carriers.dart';
import 'store.dart';

/// How many photos a folder left behind by a move still really holds:
/// its own rows, plus carriers the local index or the last bucket listing
/// name under its key that are neither a row's nor superseded
/// ([supersededCarrierKeys]), retired ([RetiredCarriers]) or queued for
/// deletion. Old copies of moved photos never count. Carriers are matched
/// by [carrierIdentity], so a name worked out in another time zone is still
/// the same carrier. No network: the index and listing are this phone's
/// copies, and the hashing runs off the UI isolate.
class HiddenLeftovers {
  HiddenLeftovers({
    required this.store,
    Future<Uint8List?> Function()? readIndex,
    VaultCipher? cipher,
  }) : _readIndex = readIndex ?? VaultStore().readIndex,
       _cipher = cipher ?? PlatformCipher();

  final AssetRecordStore store;
  final Future<Uint8List?> Function() _readIndex;
  final VaultCipher _cipher;

  Future<int> count(String tag, AlbumKeys? keys) async {
    final rows = await store.forPasscodeHash(tag);
    if (keys == null) return rows.length;
    return rows.length + (await bucketOnly(tag, keys, rows: rows)).length;
  }

  /// One entry per photo only the bucket has under [keys]: the index's
  /// where it lists one, else made from the listing name (date and size
  /// unknown until the carrier is read). A Live Photo is its still.
  Future<List<IndexEntry>> bucketOnly(
    String tag,
    AlbumKeys keys, {
    List<AssetRecord>? rows,
  }) async {
    final own = rows ?? await store.forPasscodeHash(tag);
    final elsewhere = [
      for (final r in await store.hiddenRecords())
        if (r.passcodeHash != tag) r,
    ];
    final doomed = [
      for (final t in await PendingDeletes(store: store).pending())
        ?_relative(t.objectKey),
    ];
    final retired = await RetiredCarriers(store).all();
    final index = await _readIndex();
    final listed = [
      for (final o in await store.listBucketObjects())
        if (o.directory == 'originals') (o.fileName, o.lastModified),
    ];
    final carrier = keys.carrier;
    final cipher = _cipher;
    return Isolate.run(() {
      final skip = <String>{...retired};
      void known(String? key) {
        if (key == null) return;
        skip.addAll(
          HiddenBucketScan.siblingCarrierKeysOf(key).map(carrierIdentity),
        );
      }

      for (final r in [...own, ...elsewhere]) {
        known(vaultCarrierKey(r, carrier));
        if (r.isLivePhoto) known(vaultLiveCarrierKey(r, carrier));
      }
      for (final r in own) {
        known(_relative(r.stateOf(DerivativeKind.original).destinationKey));
      }
      doomed.forEach(known);

      String stemOf(String key) {
        final id = carrierIdentity(key);
        final dot = id.lastIndexOf('.');
        return dot == -1 ? id : id.substring(0, dot);
      }

      final found = <String, IndexEntry>{};
      if (index != null) {
        try {
          for (final e in readSection(
            cipher: cipher,
            keys: keys,
            index: index,
          )) {
            if (skip.contains(carrierIdentity(e.objectKey))) continue;
            found.putIfAbsent(stemOf(e.objectKey), () => e);
          }
        } catch (_) {}
      }
      final mine = [
        for (final (name, at) in listed)
          if (nameBelongsTo(name, carrier.macKey))
            (vaultObjectKey('originals', name), at),
      ];
      final stems = <String, List<String>>{};
      for (final (key, _) in mine) {
        (stems[stemOf(key)] ??= []).add(key);
      }
      for (final (key, at) in mine) {
        if (skip.contains(carrierIdentity(key))) continue;
        final stem = stemOf(key);
        final halves = stems[stem]!;
        final isMov = key.endsWith('.mov');
        // A Live Photo is filed under its still.
        if (isMov && halves.any((k) => !k.endsWith('.mov'))) continue;
        if (found.containsKey(stem)) continue;
        final parsed = parseProtocolName(key)!;
        found[stem] = IndexEntry(
          objectKey: key,
          takenAt: parseObjectStamp(parsed.stamp) ?? at,
          width: 0,
          height: 0,
          isVideo: isMov || key.endsWith('.mp4'),
          hasMotion: !isMov && halves.length > 1,
        );
      }
      return found.values.toList();
    });
  }
}

String? _relative(String? key) {
  if (key == null) return null;
  final at = key.indexOf('originals/');
  return at == -1 ? null : key.substring(at);
}

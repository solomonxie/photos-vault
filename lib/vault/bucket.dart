import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../backup/bucket_backup.dart';
import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../upload/signing.dart';
import 'album_index.dart';
import 'carrier.dart';
import 'cipher.dart';
import 'keys.dart';
import 'store.dart';

/// Reads and writes `app-data/index.bin`, and fetches the first bytes of a
/// carrier for the grid.
///
/// The index sits beside the daily snapshot the app already writes, which
/// is what makes it unremarkable: a bucket with a non-photo object in
/// `app-data/` is every install, hidden album or not.
class VaultBucket {
  VaultBucket({
    BackupTargetsStore? targetsStore,
    VaultCipher? cipher,
    VaultStore? store,
    Future<http.Response> Function(Uri url, {Object? body})? put,
    Future<http.Response> Function(Uri url, {Map<String, String>? headers})?
    get,
  }) : _targetsStore = targetsStore ?? BackupTargetsStore(),
       _cipher = cipher ?? PlatformCipher(),
       _store = store ?? VaultStore(),
       _put = put ?? http.put,
       _get = get ?? _defaultGet;

  final BackupTargetsStore _targetsStore;
  final VaultCipher _cipher;

  /// The local mirror. Read when no bucket answers, and — this is the part
  /// that matters — used as the base a rewrite merges into, so editing one
  /// album offline cannot hand back an index with every other album's
  /// section replaced by fresh noise.
  final VaultStore _store;
  final Future<http.Response> Function(Uri url, {Object? body}) _put;
  final Future<http.Response> Function(Uri url, {Map<String, String>? headers})
  _get;

  static Future<http.Response> _defaultGet(
    Uri url, {
    Map<String, String>? headers,
  }) => http.get(url, headers: headers);

  static String _indexKey(S3BackupTarget target) =>
      BucketBackup.keyFor(target, indexObjectName);

  /// Where [objectKey] lives in [target].
  ///
  /// Index entries hold a key **relative to whatever prefix a bucket uses**
  /// — `originals/photo_x.jpg` — so one index reads against every target,
  /// and so a hidden photo has a name before any bucket exists to put it in
  /// (which is what lets the local store hold it offline). The prefix is
  /// joined on here, at the one place that talks to a bucket.
  ///
  /// Entries written by builds that stored the full key are passed through
  /// unchanged: a key that already starts with the target's prefix is
  /// already resolved, and prefixing it twice would miss.
  static String resolveKey(S3BackupTarget target, String objectKey) {
    final prefix = target.prefix;
    if (prefix.isEmpty) return objectKey;
    final normalized = prefix.endsWith('/') ? prefix : '$prefix/';
    return objectKey.startsWith(normalized)
        ? objectKey
        : '$normalized$objectKey';
  }

  /// The whole index object from the first target that has one. Null when
  /// no bucket answers — which is not the same as an empty album, and the
  /// caller must not treat it as one.
  Future<Uint8List?> loadIndex() async {
    for (final target in await _targetsStore.loadAll()) {
      try {
        final response = await _get(
          await presignGetUrl(target: target, key: _indexKey(target)),
        );
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          return response.bodyBytes;
        }
      } catch (_) {
        // Next target.
      }
    }
    return null;
  }

  /// Writes [index] to every target. Every install writes one, always the
  /// same size, whether or not anything is hidden.
  Future<bool> saveIndex(Uint8List index) async {
    var wrote = false;
    for (final target in await _targetsStore.loadAll()) {
      try {
        final response = await _put(
          await presignPutUrl(target: target, key: _indexKey(target)),
          body: index,
        );
        wrote = wrote || response.statusCode == 200;
      } catch (_) {
        // Next target.
      }
    }
    return wrote;
  }

  /// The index as it stands: the bucket's copy when one answers, mirrored
  /// locally on the way past, and the local mirror when none does.
  ///
  /// Every read and every rewrite goes through here. A rewrite that fell
  /// back to "no index" while offline would build a fresh one, and a fresh
  /// index is 32 sections of random bytes — every other album on the phone
  /// gone, silently, because the network was down.
  Future<Uint8List?> currentIndex() async {
    final remote = await loadIndex();
    if (remote != null) {
      await _store.writeIndex(remote);
      return remote;
    }
    return _store.readIndex();
  }

  /// This album's listing, and the passphrase entries riding in the
  /// plaintext header. An unused code and a mistyped one both come back
  /// empty, which is the point.
  Future<({List<IndexEntry> entries, List<PassphraseEntry> passphrases})>
  readAlbum(AlbumKeys keys) async {
    final index = await currentIndex();
    if (index == null) {
      return (entries: <IndexEntry>[], passphrases: <PassphraseEntry>[]);
    }
    return (
      entries: readSection(cipher: _cipher, keys: keys, index: index),
      passphrases: passphrasesIn(index),
    );
  }

  /// This album's slice replaced and every other one left untouched, as
  /// bytes — without writing them anywhere.
  ///
  /// Split out from [writeAlbum] because the local copy is the one that has
  /// to land: the caller writes it to the store first and only then offers it
  /// to the buckets, so an unreachable bucket costs the album nothing.
  Future<Uint8List?> encodeAlbum({
    required AlbumKeys keys,
    required List<IndexEntry> entries,
    required List<PassphraseEntry> passphrases,
  }) async {
    try {
      return writeSection(
        cipher: _cipher,
        keys: keys,
        index: await currentIndex(),
        entries: entries,
        passphrases: passphrases,
      );
    } catch (_) {
      return null;
    }
  }

  /// Replaces this album's slice, locally and in every bucket.
  Future<bool> writeAlbum({
    required AlbumKeys keys,
    required List<IndexEntry> entries,
    required List<PassphraseEntry> passphrases,
  }) async {
    final index = await encodeAlbum(
      keys: keys,
      entries: entries,
      passphrases: passphrases,
    );
    if (index == null) return false;
    await _store.writeIndex(index);
    return saveIndex(index);
  }

  /// The first [thumbnailPrefixBytes] of a carrier — enough for its
  /// thumbnail, and nowhere near the original behind it. A `Range` request,
  /// deliberately not on the background transfer: this is a grid tile, not
  /// a transfer.
  Future<Uint8List?> thumbnailPrefix(String objectKey) async {
    for (final target in await _targetsStore.loadAll()) {
      try {
        final response = await _get(
          await presignGetUrl(
            target: target,
            key: resolveKey(target, objectKey),
          ),
          headers: {'Range': 'bytes=0-${thumbnailPrefixBytes - 1}'},
        );
        if (response.statusCode == 206 || response.statusCode == 200) {
          return response.bodyBytes;
        }
      } catch (_) {
        // Next target.
      }
    }
    return null;
  }

  /// A whole carrier, for opening the photo itself.
  Future<Uint8List?> object(String objectKey) async {
    for (final target in await _targetsStore.loadAll()) {
      try {
        final response = await _get(
          await presignGetUrl(
            target: target,
            key: resolveKey(target, objectKey),
          ),
        );
        if (response.statusCode == 200) return response.bodyBytes;
      } catch (_) {
        // Next target.
      }
    }
    return null;
  }
}

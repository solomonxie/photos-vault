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
    Future<http.Response> Function(Uri url, {Object? body})? put,
    Future<http.Response> Function(Uri url, {Map<String, String>? headers})?
    get,
  }) : _targetsStore = targetsStore ?? BackupTargetsStore(),
       _cipher = cipher ?? PlatformCipher(),
       _put = put ?? http.put,
       _get = get ?? _defaultGet;

  final BackupTargetsStore _targetsStore;
  final VaultCipher _cipher;
  final Future<http.Response> Function(Uri url, {Object? body}) _put;
  final Future<http.Response> Function(Uri url, {Map<String, String>? headers})
  _get;

  static Future<http.Response> _defaultGet(
    Uri url, {
    Map<String, String>? headers,
  }) => http.get(url, headers: headers);

  static String _indexKey(S3BackupTarget target) =>
      BucketBackup.keyFor(target, indexObjectName);

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

  /// This album's listing, and the passphrase entries riding in the
  /// plaintext header. An unused code and a mistyped one both come back
  /// empty, which is the point.
  Future<({List<IndexEntry> entries, List<PassphraseEntry> passphrases})>
  readAlbum(AlbumKeys keys) async {
    final index = await loadIndex();
    if (index == null)
      return (entries: <IndexEntry>[], passphrases: <PassphraseEntry>[]);
    return (
      entries: readSection(cipher: _cipher, keys: keys, index: index),
      passphrases: passphrasesIn(index),
    );
  }

  /// Replaces this album's slice and leaves every other one untouched.
  Future<bool> writeAlbum({
    required AlbumKeys keys,
    required List<IndexEntry> entries,
    required List<PassphraseEntry> passphrases,
  }) async => saveIndex(
    writeSection(
      cipher: _cipher,
      keys: keys,
      index: await loadIndex(),
      entries: entries,
      passphrases: passphrases,
    ),
  );

  /// The first [thumbnailPrefixBytes] of a carrier — enough for its
  /// thumbnail, and nowhere near the original behind it. A `Range` request,
  /// deliberately not on the background transfer: this is a grid tile, not
  /// a transfer.
  Future<Uint8List?> thumbnailPrefix(String objectKey) async {
    for (final target in await _targetsStore.loadAll()) {
      try {
        final response = await _get(
          await presignGetUrl(target: target, key: objectKey),
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
          await presignGetUrl(target: target, key: objectKey),
        );
        if (response.statusCode == 200) return response.bodyBytes;
      } catch (_) {
        // Next target.
      }
    }
    return null;
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../backup/bucket_backup.dart';
import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../upload/bucket_http.dart';
import '../upload/s3_uploader.dart';
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
    S3Uploader? uploader,
  }) : _targetsStore = targetsStore ?? BackupTargetsStore(),
       _cipher = cipher ?? PlatformCipher(),
       _store = store ?? VaultStore(),
       _put = put ?? http.put,
       _getOverride = get,
       _uploaderOverride = uploader;

  final BackupTargetsStore _targetsStore;

  /// Carriers go up on the background transfer, like every other upload.
  final S3Uploader? _uploaderOverride;
  late final S3Uploader _uploader = _uploaderOverride ?? S3Uploader();
  final VaultCipher _cipher;

  /// The local mirror. Read when no bucket answers, and — this is the part
  /// that matters — used as the base a rewrite merges into, so editing one
  /// album offline cannot hand back an index with every other album's
  /// section replaced by fresh noise.
  final VaultStore _store;
  final Future<http.Response> Function(Uri url, {Object? body}) _put;
  final Future<http.Response> Function(Uri url, {Map<String, String>? headers})?
  _getOverride;

  /// One connection pool for every read: a grid of ranged GETs each paying
  /// its own TLS handshake is most of what scrolling an album waits on.
  http.Client? _client;

  late final Future<http.Response> Function(
    Uri url, {
    Map<String, String>? headers,
  })
  _get =
      _getOverride ??
      (url, {headers}) =>
          (_client ??= http.Client()).get(url, headers: headers);

  /// The bucket settings, read from the keychain once per [targetsTtl]
  /// rather than once per tile.
  Future<List<S3BackupTarget>>? _targets;
  DateTime _targetsAt = DateTime(0);
  static const targetsTtl = Duration(seconds: 30);

  Future<List<S3BackupTarget>> _loadTargets() {
    final now = DateTime.now();
    if (_targets == null || now.difference(_targetsAt) > targetsTtl) {
      _targetsAt = now;
      _targets = _targetsStore.loadAll()
        ..catchError((Object _) {
          _targets = null;
          return const <S3BackupTarget>[];
        });
    }
    return _targets!;
  }

  void close() {
    _client?.close();
    _client = null;
  }

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
  /// caller must not treat it as one. A torn copy counts as no answer.
  Future<Uint8List?> loadIndex() async {
    for (final target in await _targetsStore.loadAll()) {
      final found = await _indexIn(target);
      if (found.bytes != null) return found.bytes;
    }
    return null;
  }

  /// [target]'s index: bytes when whole, [absent] only on a 404. Anything
  /// else — offline, an error, a torn object — is neither.
  Future<({Uint8List? bytes, bool absent})> _indexIn(
    S3BackupTarget target,
  ) async {
    try {
      // 2 MB: a longer leash than a HEAD, but never none.
      final response = await bucketRequest(
        _get(await presignGetUrl(target: target, key: _indexKey(target))),
        timeout: const Duration(seconds: 60),
      );
      if (response.statusCode == 404) return (bytes: null, absent: true);
      if (response.statusCode == 200 && isWholeIndex(response.bodyBytes)) {
        return (bytes: response.bodyBytes, absent: false);
      }
    } catch (_) {
      // Unknown.
    }
    return (bytes: null, absent: false);
  }

  Future<bool> _putIndex(S3BackupTarget target, Uint8List index) async {
    try {
      final response = await _put(
        await presignPutUrl(target: target, key: _indexKey(target)),
        body: index,
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Writes [index] to every target. Every install writes one, always the
  /// same size, whether or not anything is hidden. True only when every
  /// target took it: one that missed would hand back the older copy. A torn
  /// index goes nowhere.
  Future<bool> saveIndex(Uint8List index) async {
    if (!isWholeIndex(index)) return false;
    final targets = await _targetsStore.loadAll();
    var wrote = 0;
    for (final target in targets) {
      if (await _putIndex(target, index)) wrote++;
    }
    return targets.isNotEmpty && wrote == targets.length;
  }

  /// Lands [index] here, marked newer than the buckets' copy until
  /// [pushIndex] gets it into every one. False, and nothing marked, when it
  /// didn't land.
  Future<bool> keepIndex(Uint8List index) async {
    if (!await _store.writeIndex(index)) return false;
    await _store.setIndexUnpublished(true);
    return true;
  }

  /// Offers [index] to every bucket, clearing the mark only if it is still
  /// what this phone holds — a newer write since stays marked.
  Future<bool> pushIndex(Uint8List index) async {
    if (!await saveIndex(index)) return false;
    final local = await _store.readIndex();
    if (local != null && _sameBytes(local, index)) {
      await _store.setIndexUnpublished(false);
    }
    return true;
  }

  Future<bool> publishIndex(Uint8List index) async {
    if (!await keepIndex(index)) return false;
    return pushIndex(index);
  }

  /// Makes sure every bucket has an `index.bin` carrying [known] in its
  /// header — on setup, on a new passphrase and on first contact with a
  /// bucket. Without it a new phone mints a fresh salt and the old
  /// passphrase opens nothing.
  ///
  /// Only ever adds: an existing index keeps every section and every
  /// header entry. A bucket with none gets this phone's mirror, or another
  /// bucket's copy, or — only when every bucket says 404 — a blank one.
  /// Checked once per bucket per set of entries. True when every bucket
  /// carries them.
  Future<bool> ensurePublished(List<PassphraseEntry> known) async {
    try {
      final local = await _store.readIndex();
      // The mirror carries them too, so a later push can't drop them.
      if (local != null && !_carries(local, known)) {
        await _store.writeIndex(indexWithPassphrases(local, known));
      }
      final targets = await _targetsStore.loadAll();
      if (targets.isEmpty) return false;
      if (await _store.isIndexUnpublished()) {
        final newer = await _store.readIndex();
        return newer != null && await pushIndex(newer);
      }
      final digest = _digestOf(known);
      final marks = await _store.readIndexMarks();
      var all = true;
      Uint8List? seed;
      var seeded = false;
      for (final target in targets) {
        if (marks[target.id] == digest) continue;
        final found = await _indexIn(target);
        Uint8List? next;
        if (found.bytes != null) {
          if (!_carries(found.bytes!, known)) {
            next = indexWithPassphrases(found.bytes, known);
          }
        } else if (found.absent) {
          if (!seeded) {
            seed = await _seed(targets);
            seeded = true;
          }
          if (seed == null) {
            all = false;
            continue;
          }
          next = _carries(seed, known)
              ? seed
              : indexWithPassphrases(seed, known);
        } else {
          all = false;
          continue;
        }
        if (next == null || await _putIndex(target, next)) {
          marks[target.id] = digest;
        } else {
          all = false;
        }
      }
      await _store.writeIndexMarks(marks);
      return all;
    } catch (_) {
      return false;
    }
  }

  /// What a bucket with no index starts from. Null when a bucket that
  /// might hold one didn't answer: a blank index there could later be read
  /// first and hide every album.
  Future<Uint8List?> _seed(List<S3BackupTarget> targets) async {
    final local = await _store.readIndex();
    if (local != null) return local;
    for (final target in targets) {
      final found = await _indexIn(target);
      if (found.bytes != null) return found.bytes;
      if (!found.absent) return null;
    }
    return emptyIndex();
  }

  static bool _carries(Uint8List index, List<PassphraseEntry> known) {
    final ids = {for (final e in passphrasesIn(index)) e.id};
    return known.every((e) => ids.contains(e.id));
  }

  static String _digestOf(List<PassphraseEntry> known) => sha256
      .convert(utf8.encode((known.map((e) => e.id).toList()..sort()).join()))
      .toString();

  /// Salt, verifier and hint of every passphrase this phone or any bucket
  /// knows — what setup tries before minting a new salt.
  Future<List<PassphraseEntry>> knownPassphrases() async {
    var known = <PassphraseEntry>[];
    final local = await _store.readIndex();
    if (local != null) known = passphrasesIn(local);
    try {
      for (final target in await _targetsStore.loadAll()) {
        final found = await _indexIn(target);
        if (found.bytes != null) {
          known = mergePassphrases(known, passphrasesIn(found.bytes!));
        }
      }
    } catch (_) {
      // What the mirror knows.
    }
    return known;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The index as it stands: the bucket's copy when one answers, mirrored
  /// locally on the way past, and the local mirror when none does.
  ///
  /// Every read and every rewrite goes through here. A rewrite that fell
  /// back to "no index" while offline would build a fresh one, and a fresh
  /// index is 32 sections of random bytes — every other album on the phone
  /// gone, silently, because the network was down.
  ///
  /// A local write the buckets never got wins over them: it is newer, and
  /// adopting theirs would drop what was hidden offline. It is offered to
  /// them again here. Another phone's edit made meanwhile loses — the
  /// lesser loss, since this phone holds the carriers its own entries list.
  Future<Uint8List?> currentIndex() async {
    if (await _store.isIndexUnpublished()) {
      final local = await _store.readIndex();
      if (local != null) {
        await pushIndex(local);
        return local;
      }
    }
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
    return publishIndex(index);
  }

  /// The first [thumbnailPrefixBytes] of a carrier — enough for its
  /// thumbnail, and nowhere near the original behind it. A `Range` request,
  /// deliberately not on the background transfer: this is a grid tile, not
  /// a transfer.
  Future<Uint8List?> thumbnailPrefix(String objectKey) async {
    for (final target in await _loadTargets()) {
      try {
        final response = await bucketRequest(
          _get(
            await presignGetUrl(
              target: target,
              key: resolveKey(target, objectKey),
            ),
            headers: {'Range': 'bytes=0-${thumbnailPrefixBytes - 1}'},
          ),
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

  /// True only when every bucket answered for [objectKey] with its bytes —
  /// a one-byte ranged read each. False with none configured.
  Future<bool> isEverywhere(String objectKey) async {
    final List<S3BackupTarget> targets;
    try {
      targets = await _targetsStore.loadAll();
    } catch (_) {
      return false;
    }
    if (targets.isEmpty) return false;
    for (final target in targets) {
      try {
        final response = await bucketRequest(
          _get(
            await presignGetUrl(
              target: target,
              key: resolveKey(target, objectKey),
            ),
            headers: {'Range': 'bytes=0-0'},
          ),
        );
        if (response.statusCode != 206 && response.statusCode != 200) {
          return false;
        }
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  /// True only when every bucket answered 404 for [objectKey] — a one-byte
  /// ranged read, so a dead network is not mistaken for a deleted carrier.
  Future<bool> isAbsent(String objectKey) async {
    final targets = await _targetsStore.loadAll();
    if (targets.isEmpty) return false;
    for (final target in targets) {
      try {
        final response = await bucketRequest(
          _get(
            await presignGetUrl(
              target: target,
              key: resolveKey(target, objectKey),
            ),
            headers: {'Range': 'bytes=0-0'},
          ),
        );
        if (response.statusCode != 404) return false;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  /// A whole carrier, or [absent] when every bucket answered 404. Unreachable is neither: a caller deciding "there is no
  /// such object" must not mistake a dead network for it.
  Future<({Uint8List? bytes, bool absent})> fetch(String objectKey) async {
    var missing = 0;
    final targets = await _targetsStore.loadAll();
    for (final target in targets) {
      try {
        final response = await _get(
          await presignGetUrl(
            target: target,
            key: resolveKey(target, objectKey),
          ),
        );
        if (response.statusCode == 200) {
          return (bytes: response.bodyBytes, absent: false);
        }
        if (response.statusCode == 404) missing++;
      } catch (_) {
        // Next target.
      }
    }
    // No bucket to ask (a keychain that didn't answer) is not "absent".
    return (
      bytes: null,
      absent: targets.isNotEmpty && missing == targets.length,
    );
  }

  /// Puts a local carrier into every bucket. True only when every one took
  /// it, and false with none configured — there is nowhere it has gone.
  Future<bool> putEverywhere(File carrier, String objectKey) async {
    final targets = await _targetsStore.loadAll();
    if (targets.isEmpty) return false;
    var wrote = 0;
    for (final target in targets) {
      if (await _uploader.put(
        filePath: carrier.path,
        key: resolveKey(target, objectKey),
        target: target,
      )) {
        wrote++;
      }
    }
    return wrote == targets.length;
  }

  /// A whole carrier, for opening the photo itself.
  Future<Uint8List?> object(String objectKey) async {
    for (final target in await _loadTargets()) {
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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'carrier.dart';
import 'cipher.dart';
import 'keys.dart';

/// Marks a directory as excluded from the iOS device backup —
/// `ios/Runner/BackupExclusionChannel.swift`.
///
/// iOS has no directory that is both durable and out of the backup:
/// Application Support is kept forever and backed up, Caches is out of the
/// backup and purgeable. An offline-first vault needs both properties, so it
/// takes the durable one and turns the backup off.
///
/// Returns false when it could not be set — not an error worth failing a
/// write over: the files still work, they would just ride into the owner's
/// iCloud backup and eat their quota.
class BackupExclusion {
  const BackupExclusion();

  static const _channel = MethodChannel('byo.photos/backup_exclusion');

  Future<bool> exclude(String path) async {
    try {
      return await _channel.invokeMethod<bool>('exclude', {'path': path}) ??
          false;
    } catch (_) {
      // No channel (a test, a dev shell, Android) — nothing to exclude.
      return false;
    }
  }
}

/// Where hidden photos actually live on this phone.
///
/// This is what makes the private album **offline-first, with the bucket
/// optional** rather than the other way round. Before it, a hidden photo was
/// removed from Photos, uploaded as a carrier, and then deleted locally
/// along with its database row: the bucket held the only copy, and with no
/// bucket, or no signal, an album was a grid of nothing.
///
/// What is kept, and why each one:
///
/// ```text
/// <Application Support>/vault/          ← excluded from the device backup
/// ├── index.bin                 the album listing, so the grid opens offline
/// ├── index.unpublished         present while index.bin is newer than the
/// │                             buckets' copy
/// ├── carriers/<hmac>           the whole carrier, byte-for-byte what the
/// │                             bucket holds — so it is the local copy and
/// │                             the upload body at once
/// └── thumbnails/<hmac>         encrypted tile only, kept when the user has
///                               sent a photo's full copy back to the bucket
/// ```
///
/// **The carrier is stored as-is.** It is already AES-CTR under the album
/// key, already MAC'd, and already a real openable JPEG or MP4 of somebody
/// else's picture (see `carrier.dart`). Re-encrypting it would be a second
/// lock on the same door, and keeping the plaintext instead would undo the
/// feature. It also means "upload" is a PUT of a file that already exists,
/// "download" writes one file, and the local and remote copies can be
/// compared byte for byte.
///
/// **Names are HMACs of the object key under the album key**, as in
/// `cache.dart`: a directory listing is then a list of equal-looking blobs
/// that says nothing about how many albums there are or which photo is
/// which. The plausible-photo part of the disguise is in the file's
/// *contents*, which is where it belongs — a forensic dump reads bytes, and
/// these bytes open as a picture.
///
/// **Nothing here is evicted.** No TTL, no size cap: that is the difference
/// between this and `VaultCache`, which exists to make re-fetching cheap and
/// is free to throw anything away. A file leaves here when the user sends
/// that photo back to the bucket, or when it or its album is deleted.
/// Remove All App Data leaves it alone: it may be the only copy.
class VaultStore {
  VaultStore({
    Future<Directory> Function()? directory,
    VaultCipher? cipher,
    BackupExclusion? exclusion,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       _cipher = cipher ?? PlatformCipher(),
       _exclusion = exclusion ?? const BackupExclusion();

  final Future<Directory> Function() _directory;
  final VaultCipher _cipher;
  final BackupExclusion _exclusion;

  /// The one directory this owns.
  static const root = 'vault';

  static const carriersDir = 'carriers';
  static const thumbnailsDir = 'thumbnails';
  static const unsentDir = 'unsent';
  static const indexFileName = 'index.bin';
  static const unpublishedFileName = 'index.unpublished';

  Future<Directory> _root() async {
    final dir = Directory(p.join((await _directory()).path, root));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      // Every file created inside inherits it, so this is the only place it
      // has to be set — and it is set on creation rather than remembered.
      await _exclusion.exclude(dir.path);
    }
    return dir;
  }

  Future<Directory> _pool(String name) async {
    final dir = Directory(p.join((await _root()).path, name));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Names nothing: the object key hashed under the album key, so two
  /// albums' files are indistinguishable and neither is countable.
  String _fileName(AlbumKeys keys, String objectKey) => vaultHmac(
    keys.albumKey,
    objectKey.codeUnits,
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // ------------------------------------------------------------- the index

  /// The album listing as last seen, so opening the album offline shows the
  /// album rather than an empty grid.
  ///
  /// The same bytes as the bucket's `app-data/index.bin` — one blob holding
  /// every album's padded section, readable only with an album key. Kept
  /// whole rather than per album for exactly that reason: a per-album file
  /// would make the number of albums a directory listing.
  Future<Uint8List?> readIndex() async {
    try {
      final file = File(p.join((await _root()).path, indexFileName));
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> writeIndex(Uint8List index) async {
    try {
      final file = File(p.join((await _root()).path, indexFileName));
      await file.writeAsBytes(index, flush: true);
    } catch (_) {
      // The bucket's copy still stands; the album just won't open offline.
    }
  }

  /// Marks the local index as newer than any bucket's: written here, not
  /// yet in every bucket. While set, the bucket's copy is older and must
  /// not replace it.
  Future<void> setIndexUnpublished(bool value) async {
    try {
      final file = File(p.join((await _root()).path, unpublishedFileName));
      if (value) {
        await file.writeAsBytes(const [1], flush: true);
      } else if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Unwritable root: the index write above failed the same way.
    }
  }

  Future<bool> isIndexUnpublished() async {
    try {
      return await File(p.join((await _root()).path, unpublishedFileName))
          .exists();
    } catch (_) {
      return false;
    }
  }

  // ----------------------------------------------------------- the carrier

  Future<File> carrierFile(AlbumKeys keys, String objectKey) async =>
      File(p.join((await _pool(carriersDir)).path, _fileName(keys, objectKey)));

  Future<bool> hasCarrier(AlbumKeys keys, String objectKey) async {
    try {
      return await (await carrierFile(keys, objectKey)).exists();
    } catch (_) {
      return false;
    }
  }

  /// Takes ownership of a freshly built carrier. Copied rather than moved:
  /// the caller's file is a temp the upload still has to read.
  Future<File?> putCarrier(
    AlbumKeys keys,
    String objectKey,
    File carrier,
  ) async {
    try {
      final target = await carrierFile(keys, objectKey);
      await carrier.copy(target.path);
      return target;
    } catch (_) {
      return null;
    }
  }

  Future<File?> putCarrierBytes(
    AlbumKeys keys,
    String objectKey,
    Uint8List bytes,
  ) async {
    try {
      final target = await carrierFile(keys, objectKey);
      await target.writeAsBytes(bytes, flush: true);
      return target;
    } catch (_) {
      return null;
    }
  }

  /// The carrier's first [thumbnailPrefixBytes], for a grid tile — read with
  /// a seek rather than by loading the file, because the whole point of the
  /// thumbnail living at the front is not touching the original behind it.
  Future<Uint8List?> carrierPrefix(AlbumKeys keys, String objectKey) async {
    RandomAccessFile? handle;
    try {
      final file = await carrierFile(keys, objectKey);
      if (!await file.exists()) return null;
      handle = await file.open();
      return await handle.read(thumbnailPrefixBytes);
    } catch (_) {
      return null;
    } finally {
      await handle?.close();
    }
  }

  Future<Uint8List?> readCarrier(AlbumKeys keys, String objectKey) async {
    try {
      final file = await carrierFile(keys, objectKey);
      return await file.exists() ? await file.readAsBytes() : null;
    } catch (_) {
      return null;
    }
  }

  /// Drops the local carrier and keeps [thumbnail] in its place, which is
  /// what "in the bucket only" means here: the tile still draws, offline,
  /// and the photo itself is one download away.
  Future<bool> sendBackToBucket(
    AlbumKeys keys,
    String objectKey, {
    required Uint8List? thumbnail,
  }) async {
    try {
      if (thumbnail != null) {
        await writeThumbnail(keys, objectKey, thumbnail);
      }
      final file = await carrierFile(keys, objectKey);
      if (await file.exists()) await file.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------- not yet sent

  /// Marks a carrier filed with no bucket to hold it, so it goes up once
  /// one exists. Named like the carrier: a listing says nothing new.
  ///
  /// Holds the object key sealed under the outbox key, which is what lets
  /// [sendUnsent] work with no album open. Markers from before that hold a
  /// bare byte and wait for their album, as they always did.
  Future<void> setUnsent(AlbumKeys keys, String objectKey, bool value) async {
    try {
      final file = File(
        p.join((await _pool(unsentDir)).path, _fileName(keys, objectKey)),
      );
      if (value) {
        final outbox = keys.outboxKey;
        await file.writeAsBytes(
          outbox == null
              ? const [1]
              : _sealName(keys.entry.id, outbox, objectKey),
          flush: true,
        );
      } else if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Unmarked: the carrier still opens here, it just isn't offered up.
    }
  }

  List<int> _sealName(String entryId, Uint8List key, String objectKey) {
    final iv = randomBytes(16);
    final sealed = _cipher.transform(
      key: key,
      iv: iv,
      data: Uint8List.fromList(utf8.encode(objectKey)),
    );
    return utf8.encode(
      jsonEncode({
        'e': entryId,
        'iv': base64Encode(iv),
        'c': base64Encode(sealed),
        'm': base64Encode(vaultHmac(key, [...iv, ...sealed])),
      }),
    );
  }

  /// Sends every sealed unsent carrier with [put], album open or not, and
  /// unmarks what every bucket took. Returns how many went.
  Future<int> sendUnsent({
    required Future<Uint8List?> Function(String entryId) outboxKey,
    required Future<bool> Function(File carrier, String objectKey) put,
  }) async {
    var sent = 0;
    try {
      final carriers = await _pool(carriersDir);
      await for (final marker in (await _pool(unsentDir)).list()) {
        if (marker is! File) continue;
        final objectKey = await _openName(marker, outboxKey);
        if (objectKey == null) continue;
        final carrier = File(p.join(carriers.path, p.basename(marker.path)));
        if (!await carrier.exists()) continue;
        if (!await put(carrier, objectKey)) continue;
        try {
          await marker.delete();
        } catch (_) {
          // The album's own send got there first.
        }
        sent++;
      }
    } catch (_) {
      // Still marked; the next sync tries again.
    }
    return sent;
  }

  Future<String?> _openName(
    File marker,
    Future<Uint8List?> Function(String entryId) outboxKey,
  ) async {
    try {
      final json = jsonDecode(
        utf8.decode(await marker.readAsBytes()),
      ) as Map<String, dynamic>;
      final key = await outboxKey(json['e'] as String);
      if (key == null) return null;
      final iv = base64Decode(json['iv'] as String);
      final sealed = base64Decode(json['c'] as String);
      if (!bytesMatch(
        base64Decode(json['m'] as String),
        vaultHmac(key, [...iv, ...sealed]),
      )) {
        return null;
      }
      return utf8.decode(_cipher.transform(key: key, iv: iv, data: sealed));
    } catch (_) {
      // A bare legacy marker, or not ours to read.
      return null;
    }
  }

  Future<bool> isUnsent(AlbumKeys keys, String objectKey) async {
    try {
      return await File(
        p.join((await _pool(unsentDir)).path, _fileName(keys, objectKey)),
      ).exists();
    } catch (_) {
      return false;
    }
  }

  // --------------------------------------------------------- the thumbnail

  /// Encrypted, unlike the carrier, because a thumbnail on its own is not a
  /// carrier — it has no decoy around it, so left in the clear it would be a
  /// small picture of a hidden photo sitting on the disk.
  Future<void> writeThumbnail(
    AlbumKeys keys,
    String objectKey,
    Uint8List bytes,
  ) async {
    try {
      final iv = randomBytes(16);
      final file = File(
        p.join((await _pool(thumbnailsDir)).path, _fileName(keys, objectKey)),
      );
      await file.writeAsBytes([
        ...iv,
        ..._cipher.transform(key: keys.carrier.encKey, iv: iv, data: bytes),
      ], flush: true);
    } catch (_) {
      // The carrier or the bucket can still produce one.
    }
  }

  Future<Uint8List?> readThumbnail(AlbumKeys keys, String objectKey) async {
    try {
      final file = File(
        p.join((await _pool(thumbnailsDir)).path, _fileName(keys, objectKey)),
      );
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.length <= 16) return null;
      return _cipher.transform(
        key: keys.carrier.encKey,
        iv: Uint8List.sublistView(bytes, 0, 16),
        data: Uint8List.sublistView(bytes, 16),
      );
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------ the totals

  /// What the private side is costing on this phone, and how much of it is
  /// full copies — the two numbers the album's footer needs to offer
  /// "send some of this back to the bucket" honestly.
  Future<({int carriers, int carrierBytes, int thumbnailBytes})> usage() async {
    var carriers = 0;
    var carrierBytes = 0;
    var thumbnailBytes = 0;
    try {
      await for (final entity in (await _pool(carriersDir)).list()) {
        if (entity is! File) continue;
        carriers++;
        carrierBytes += await entity.length();
      }
      await for (final entity in (await _pool(thumbnailsDir)).list()) {
        if (entity is! File) continue;
        thumbnailBytes += await entity.length();
      }
    } catch (_) {
      // Best effort: a footer is not worth failing over.
    }
    return (
      carriers: carriers,
      carrierBytes: carrierBytes,
      thumbnailBytes: thumbnailBytes,
    );
  }

  /// Everything, for a forgotten passphrase.
  Future<void> clear() async {
    try {
      final dir = Directory(p.join((await _directory()).path, root));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Nothing there, or nothing we can do about it.
    }
  }

  /// Just this album's files, for emptying one album without touching the
  /// others. Named by [objectKeys] because there is no other way to know
  /// which blobs are whose.
  Future<void> removeAll(AlbumKeys keys, Iterable<String> objectKeys) async {
    for (final objectKey in objectKeys) {
      try {
        final carrier = await carrierFile(keys, objectKey);
        if (await carrier.exists()) await carrier.delete();
        final thumbnail = File(
          p.join((await _pool(thumbnailsDir)).path, _fileName(keys, objectKey)),
        );
        if (await thumbnail.exists()) await thumbnail.delete();
        await setUnsent(keys, objectKey, false);
      } catch (_) {
        // Next one.
      }
    }
  }
}

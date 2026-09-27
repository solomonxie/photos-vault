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
/// that photo back to the bucket, when the album is emptied, or when Remove
/// All App Data runs.
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

  /// The one directory this owns. Public because Remove All App Data has to
  /// delete it, and a second spelling of 'vault' is a directory that quietly
  /// survives the wipe.
  static const root = 'vault';

  static const carriersDir = 'carriers';
  static const thumbnailsDir = 'thumbnails';
  static const indexFileName = 'index.bin';

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

  /// Everything, for Remove All App Data and for a forgotten passphrase.
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
      } catch (_) {
        // Next one.
      }
    }
  }
}

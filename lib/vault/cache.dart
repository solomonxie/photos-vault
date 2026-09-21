import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'carrier.dart';
import 'cipher.dart';
import 'keys.dart';

/// Where a hidden photo may touch the disk: a cache, and only a cache.
///
/// `Library/Caches`, not Application Support, and the difference is the
/// whole point — Application Support (where `ThumbnailCache` writes) is
/// **included in the iOS device backup**, so a thumbnail there rides into
/// the owner's own iCloud backup. Caches is excluded from the backup, is
/// not reachable from the Files app, and the OS may purge it, which is
/// exactly the behaviour wanted here.
///
/// Everything in it is encrypted with the album key and named after it, so
/// a purge that leaves recoverable blocks, a forensic image or a jailbroken
/// dump all get ciphertext under meaningless names.
enum CachePool {
  /// Grid tiles. Cheap to fetch again: one 64 KB ranged GET.
  thumbnail(capBytes: 100 * 1024 * 1024, ttl: Duration(days: 30)),

  /// Full-size photos and Live Photos, fetched when one is opened.
  photo(capBytes: 500 * 1024 * 1024, ttl: Duration(days: 30)),

  /// Videos, which cost minutes and somebody's data plan to fetch again,
  /// so they get the long tail and the big share.
  video(capBytes: 2 * 1024 * 1024 * 1024, ttl: Duration(days: 90));

  const CachePool({required this.capBytes, required this.ttl});

  final int capBytes;
  final Duration ttl;

  String get dirName => name;
}

class VaultCache {
  VaultCache({Future<Directory> Function()? directory, VaultCipher? cipher})
    : _directory = directory ?? getApplicationCacheDirectory,
      _cipher = cipher ?? PlatformCipher();

  final Future<Directory> Function() _directory;
  final VaultCipher _cipher;

  static const _root = 'vault';

  Future<Directory> _poolDirectory(CachePool pool) async {
    final dir = Directory(
      p.join((await _directory()).path, _root, pool.dirName),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Names nothing: an object key hashed under the album key, so the
  /// directory listing is meaningless without it.
  String _fileName(AlbumKeys keys, String objectKey) => vaultHmac(
    keys.albumKey,
    objectKey.codeUnits,
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<File> _fileFor(
    CachePool pool,
    AlbumKeys keys,
    String objectKey,
  ) async => File(
    p.join((await _poolDirectory(pool)).path, _fileName(keys, objectKey)),
  );

  Future<Uint8List?> read(
    CachePool pool,
    AlbumKeys keys,
    String objectKey,
  ) async {
    final file = await _fileFor(pool, keys, objectKey);
    try {
      if (!await file.exists()) return null;
      final stat = await file.stat();
      if (DateTime.now().difference(stat.modified) > pool.ttl) {
        await file.delete();
        return null;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length <= 16) return null;
      final plain = _cipher.transform(
        key: keys.carrier.encKey,
        iv: Uint8List.sublistView(bytes, 0, 16),
        data: Uint8List.sublistView(bytes, 16),
      );
      // Touch it, so LRU means what it says.
      await file.setLastModified(DateTime.now());
      return plain;
    } catch (_) {
      // A cache miss is always a valid answer.
      return null;
    }
  }

  Future<void> write(
    CachePool pool,
    AlbumKeys keys,
    String objectKey,
    Uint8List bytes,
  ) async {
    try {
      final iv = randomBytes(16);
      final file = await _fileFor(pool, keys, objectKey);
      await file.writeAsBytes([
        ...iv,
        ..._cipher.transform(key: keys.carrier.encKey, iv: iv, data: bytes),
      ], flush: true);
      await _evict(pool);
    } catch (_) {
      // Failing to cache is not failing.
    }
  }

  /// Oldest first, until the pool is back under its cap. Expired entries go
  /// whatever the size is.
  Future<void> _evict(CachePool pool) async {
    final dir = await _poolDirectory(pool);
    final files = <File, FileStat>{};
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      files[entity] = await entity.stat();
    }
    final now = DateTime.now();
    var total = 0;
    final living = <File, FileStat>{};
    for (final entry in files.entries) {
      if (now.difference(entry.value.modified) > pool.ttl) {
        await entry.key.delete();
        continue;
      }
      living[entry.key] = entry.value;
      total += entry.value.size;
    }
    if (total <= pool.capBytes) return;
    final oldest = living.keys.toList()
      ..sort((a, b) => living[a]!.modified.compareTo(living[b]!.modified));
    for (final file in oldest) {
      if (total <= pool.capBytes) break;
      total -= living[file]!.size;
      await file.delete();
    }
  }

  /// Everything, for when the passphrase is forgotten on this phone.
  Future<void> clear() async {
    final dir = Directory(p.join((await _directory()).path, _root));
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

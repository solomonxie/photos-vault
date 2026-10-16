import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/vault/cache.dart';
import 'package:photos_vault/vault/keys.dart';

AlbumKeys _keys() => AlbumKeys(
  albumKey: Uint8List.fromList(List.generate(32, (i) => i)),
  entry: PassphraseEntry(
    id: 'e',
    salt: Uint8List(16),
    verifier: Uint8List(32),
    hint: '',
  ),
);

void main() {
  late Directory dir;
  late VaultCache cache;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pv_vault_cache_');
    cache = VaultCache(directory: () async => dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  for (final size in [10 * 1024, 3 * 1024 * 1024]) {
    test('$size bytes come back as written, sealed on disk', () async {
      final keys = _keys();
      final bytes = Uint8List.fromList(List.generate(size, (i) => i % 251));
      await cache.write(CachePool.video, keys, 'originals/a.mp4', bytes);

      final files = Directory('${dir.path}/${VaultCache.root}/video')
          .listSync()
          .whereType<File>()
          .toList();
      expect(files, hasLength(1));
      final onDisk = files.single.readAsBytesSync();
      expect(onDisk.length, size + 16);
      expect(onDisk.sublist(16, 48), isNot(bytes.sublist(0, 32)));

      expect(await cache.read(CachePool.video, keys, 'originals/a.mp4'), bytes);
    });
  }
}

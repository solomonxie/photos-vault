import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/vault/album_index.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/filed_photos.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/object_key.dart';
import 'package:photos_vault/vault/store.dart';

import '../support/fake_asset_record_store.dart';
import 'carrier_fixtures.dart';

class _NoExclusion extends BackupExclusion {
  const _NoExclusion();

  @override
  Future<bool> exclude(String path) async => true;
}

void main() {
  final keys = AlbumKeys(
    albumKey: Uint8List.fromList(List.generate(32, (i) => i)),
    entry: PassphraseEntry(
      id: 'e1',
      salt: Uint8List(16),
      verifier: Uint8List(32),
      hint: '',
    ),
    outboxKey: Uint8List(32),
  );
  final original = Uint8List.fromList(List.generate(5000, (i) => i % 251));

  late Directory dir;
  late FakeAssetRecordStore records;
  late VaultStore store;
  late FiledPhotos filed;

  Uint8List carrier() => buildJpegCarrier(
    cipher: PlatformCipher(),
    keys: keys.carrier,
    masterSalt: keys.entry.salt,
    decoy: decoyJpeg(),
    thumbnail: Uint8List.fromList([1, 2, 3]),
    original: original,
    extension: 'jpg',
  )!;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pv_filed_');
    records = FakeAssetRecordStore();
    store = VaultStore(
      directory: () async => dir,
      exclusion: const _NoExclusion(),
    );
    filed = FiledPhotos(
      records: records,
      store: store,
      directory: () async => dir,
      hashFile: (_) async => 'hash',
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a row whose plain file went gets it back from the carrier', () async {
    final record = await records.upsert(
      localId: 'manual:one',
      contentHash: 'c',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
    );
    await records.setPasscodeHash('manual:one', 'h');
    await store.putCarrierBytes(
      keys,
      vaultCarrierKey(record, keys.carrier),
      carrier(),
    );

    expect(await filed.restoreRow(keys, record), isTrue);
    final path = (await records.getByLocalId('manual:one'))!.sourcePath!;
    expect(File(path).readAsBytesSync(), original);
  });

  test('an entry with no row becomes an ordinary hidden photo, backed up, '
      'with no second copy left here', () async {
    const key = 'originals/20260901120000_abc.jpg';
    await store.putCarrierBytes(keys, key, carrier());
    final entry = IndexEntry(
      objectKey: key,
      takenAt: DateTime(2026, 9, 1, 12),
      width: 640,
      height: 480,
      isVideo: false,
    );

    final record = (await filed.adopt(keys, 'h', entry))!;
    expect(record.passcodeHash, 'h');
    expect(record.createdAt, DateTime(2026, 9, 1, 12));
    expect(record.isFullyBackedUp, isTrue);
    expect(record.stateOf(DerivativeKind.original).destinationKey, key);
    expect(File(record.sourcePath!).readAsBytesSync(), original);
    expect(await store.hasCarrier(keys, key), isFalse);
  });

  test('a carrier never sent is left as it is: it is the only copy', () async {
    const key = 'originals/20260901120000_def.jpg';
    await store.putCarrierBytes(keys, key, carrier());
    await store.setUnsent(keys, key, true);
    final entry = IndexEntry(
      objectKey: key,
      takenAt: DateTime(2026, 9, 1),
      width: 1,
      height: 1,
      isVideo: false,
    );

    expect(await filed.adopt(keys, 'h', entry), isNull);
    expect(await store.hasCarrier(keys, key), isTrue);
  });
}

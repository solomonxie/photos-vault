import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/secure_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/vault/album_index.dart';
import 'package:photos_vault/vault/bucket.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/filed_photos.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/object_key.dart';
import 'package:photos_vault/vault/store.dart';

import '../support/fake_asset_record_store.dart';
import 'carrier_fixtures.dart';

class _MemoryStore implements SecureStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

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

  /// Object keys the fake bucket answers for; everything else is a 404.
  late Set<String> inBucket;

  Uint8List carrier({Uint8List? bytes, String extension = 'jpg'}) =>
      buildJpegCarrier(
        cipher: PlatformCipher(),
        keys: keys.carrier,
        masterSalt: keys.entry.salt,
        decoy: decoyJpeg(),
        thumbnail: Uint8List.fromList([1, 2, 3]),
        original: bytes ?? original,
        extension: extension,
      )!;
  final motion = Uint8List.fromList(List.generate(3000, (i) => i % 7));

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('pv_filed_');
    records = FakeAssetRecordStore();
    store = VaultStore(
      directory: () async => dir,
      exclusion: const _NoExclusion(),
    );
    inBucket = {};
    final targets = BackupTargetsStore(store: _MemoryStore());
    await targets.add(
      accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
      secretAccessKey: 'secret',
      region: 'us-east-1',
      bucket: 'my-bucket',
      prefix: '',
    );
    filed = FiledPhotos(
      records: records,
      store: store,
      bucket: VaultBucket(
        targetsStore: targets,
        store: store,
        get: (url, {headers}) async =>
            inBucket.any((key) => url.path.endsWith(key))
            ? http.Response('x', 206)
            : http.Response('', 404),
      ),
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
    inBucket.add(key);
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

  test('an entry whose carrier the bucket no longer holds is adopted as '
      'not backed up, and its carrier stays here', () async {
    const key = 'originals/20260901120000_lost.jpg';
    await store.putCarrierBytes(keys, key, carrier());
    final entry = IndexEntry(
      objectKey: key,
      takenAt: DateTime(2026, 9, 1),
      width: 1,
      height: 1,
      isVideo: false,
    );

    final record = (await filed.adopt(keys, 'h', entry))!;
    expect(record.isFullyBackedUp, isFalse);
    expect(
      record.stateOf(DerivativeKind.original).status,
      UploadStatus.pending,
    );
    expect(await store.hasCarrier(keys, key), isTrue);
  });

  test(
    'a .mov never sent keeps its carrier and is not marked backed up',
    () async {
      const key = 'originals/20260901120000_ccc.jpg';
      const motionKey = 'originals/20260901120000_ccc.mov';
      inBucket.addAll([key, motionKey]);
      await store.putCarrierBytes(keys, key, carrier());
      await store.putCarrierBytes(
        keys,
        motionKey,
        carrier(bytes: motion, extension: 'mov'),
      );
      await store.setUnsent(keys, motionKey, true);
      final entry = IndexEntry(
        objectKey: key,
        takenAt: DateTime(2026, 9, 1),
        width: 1,
        height: 1,
        isVideo: false,
        hasMotion: true,
      );

      final record = (await filed.adopt(keys, 'h', entry))!;
      expect(
        record.stateOf(DerivativeKind.livePhoto).status,
        UploadStatus.pending,
      );
      expect(await store.hasCarrier(keys, motionKey), isTrue);
    },
  );

  test('an entry filed before motion was recorded keeps its .mov', () async {
    const key = 'originals/20260901120000_aaa.jpg';
    const motionKey = 'originals/20260901120000_aaa.mov';
    inBucket.addAll([key, motionKey]);
    await store.putCarrierBytes(keys, key, carrier());
    await store.putCarrierBytes(
      keys,
      motionKey,
      carrier(bytes: motion, extension: 'mov'),
    );
    final entry = IndexEntry(
      objectKey: key,
      takenAt: DateTime(2026, 9, 1),
      width: 1,
      height: 1,
      isVideo: false,
    );

    final record = (await filed.adopt(keys, 'h', entry))!;
    expect(record.isLivePhoto, isTrue);
    expect(File('${record.sourcePath}.live.mov').readAsBytesSync(), motion);
    expect(record.stateOf(DerivativeKind.livePhoto).destinationKey, motionKey);
    expect(await store.hasCarrier(keys, motionKey), isFalse);
  });

  test('a row adopted as a still moves again once its .mov is found, and '
      'is checked only once', () async {
    const key = 'originals/20260901120000_bbb.jpg';
    const motionKey = 'originals/20260901120000_bbb.mov';
    final still = File('${dir.path}/hidden_bbb.jpg')
      ..writeAsBytesSync(original);
    await records.upsert(
      localId: 'manual:vault-20260901120000_bbb',
      contentHash: 'c',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: still.path,
    );
    await records.updateDerivative(
      'manual:vault-20260901120000_bbb',
      DerivativeKind.original,
      const DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
    );
    await store.putCarrierBytes(
      keys,
      motionKey,
      carrier(bytes: motion, extension: 'mov'),
    );
    final rows = [
      (await records.getByLocalId('manual:vault-20260901120000_bbb'))!,
    ];

    expect(await filed.repairMotion(keys, rows), isTrue);
    final fixed = (await records.getByLocalId(rows.single.localId))!;
    expect(fixed.isLivePhoto, isTrue);
    expect(File('${still.path}.live.mov').readAsBytesSync(), motion);
    expect(await filed.repairMotion(keys, rows), isFalse);
  });
}

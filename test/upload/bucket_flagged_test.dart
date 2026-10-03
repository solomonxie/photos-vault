import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:photos_vault/upload/bucket_flagged.dart';
import 'package:photos_vault/upload/bucket_import.dart';
import 'package:photos_vault/upload/name_migration.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/object_key.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/memory_bucket.dart';
import '../vault/carrier_fixtures.dart';

void main() {
  late FakeAssetRecordStore store;
  late BackupTargetsStore targets;
  late S3BackupTarget target;
  late MemoryBucket bucket;

  final cipher = PlatformCipher();
  final albumKey = Uint8List.fromList(List.generate(32, (i) => i));
  final keys = CarrierKeys.forAlbum(albumKey);
  final knownSalt = Uint8List.fromList(List.generate(16, (i) => i * 3));
  final known = PassphraseEntry(
    id: 'e',
    salt: knownSalt,
    verifier: Uint8List(32),
    hint: '',
  );
  final video = Uint8List.fromList(List.generate(5000, (i) => i % 251));

  Uint8List carrier({required Uint8List salt, bool v2 = true}) =>
      buildJpegCarrier(
        cipher: cipher,
        keys: keys,
        masterSalt: salt,
        decoy: decoyJpeg(),
        thumbnail: Uint8List.fromList(List.generate(3000, (i) => i % 200)),
        original: Uint8List.fromList(List.generate(20000, (i) => i % 250)),
        extension: 'jpg',
        nonce: v2 ? Uint8List.fromList(List.generate(8, (i) => i + 9)) : null,
        meta: v2
            ? CarrierMeta(
                takenAt: DateTime(2024, 5, 6),
                width: 10,
                height: 20,
                isVideo: false,
              )
            : null,
      )!;

  Future<List<BucketObject>> relist() async {
    final rows = [
      for (final dir in ['originals/', 'thumbnails/'])
        for (final o in (await bucket.listFolder(target, dir))!)
          BucketObject(
            targetId: target.id,
            key: o.key,
            size: o.size,
            lastModified: o.lastModified,
          ),
    ];
    await store.replaceBucketObjects(target.id, rows);
    return rows;
  }

  BucketFixer fixer() => BucketFixer(
    store: store,
    targetsStore: targets,
    passphrases: () async => [known],
    ops: bucket,
  );

  setUp(() async {
    store = FakeAssetRecordStore();
    targets = BackupTargetsStore(store: FakeSecureStore());
    target = await targets.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'b',
      prefix: 'photos-vault/',
    );
    bucket = MemoryBucket();
  });

  test('takenAtFromName reads the camera timestamp', () {
    expect(
      takenAtFromName('import_20251228120340_179792A.mp4'),
      DateTime(2025, 12, 28, 12, 3, 40),
    );
    expect(takenAtFromName('holiday.mp4'), isNull);
    expect(takenAtFromName('import_99999999999999.mp4'), isNull);
  });

  group('flags', () {
    test('an unknown off-protocol file is flagged, never skipped', () async {
      bucket.objects['photos-vault/originals/import_2025_clip.mp4'] = video;
      bucket.objects['photos-vault/originals/photo_OLD_L0_001.webp'] = video;
      await relist();

      final flagged = await BucketFlags(store: store).detect();

      expect(flagged.map((f) => f.name), [
        'import_2025_clip.mp4',
        'photo_OLD_L0_001.webp',
      ]);
    });

    test('a protocol-shaped name is left to the albums', () async {
      final name = '${hiddenBaseName(keys, _record('x'))}.jpg';
      bucket.objects['photos-vault/originals/$name'] = video;
      await relist();

      expect(await BucketFlags(store: store).detect(), isEmpty);
    });

    test('a file a record points at is known', () async {
      bucket.objects['photos-vault/originals/photo_OLD_L0_001.webp'] = video;
      await relist();
      await store.upsert(localId: 'a', contentHash: 'a', platform: 'ios');
      await store.updateDerivative(
        'a',
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'photos-vault/originals/photo_OLD_L0_001.webp',
        ),
      );

      expect(await BucketFlags(store: store).detect(), isEmpty);
    });

    test('a thumbnail without its original is an orphan', () async {
      bucket.objects['photos-vault/thumbnails/gone.jpg'] = video;
      await relist();

      final flagged = await BucketFlags(store: store).detect();

      expect(flagged.single.kind, FlagKind.orphanThumbnail);
    });
  });

  group('rename', () {
    test('an ordinary video becomes a record under a protocol name', () async {
      bucket.objects['photos-vault/originals/import_20251228120340_a.mp4'] =
          video;
      bucket.objects['photos-vault/thumbnails/import_20251228120340_a.jpg'] =
          Uint8List(10);
      await relist();
      final item = (await BucketFlags(store: store).detect()).single;

      final result = await fixer().rename(item);

      expect(result.outcome, FixOutcome.imported);
      final names = bucket.objects.keys.map((k) => k.split('/').last).toList();
      expect(names.every(fitsProtocol), isTrue);
      expect(names.length, 2, reason: 'original and thumbnail, old ones gone');
      final record = (await store.getByLocalId(result.localId!))!;
      expect(record.isVideo, isTrue);
      expect(record.localDeleted, isTrue);
      expect(record.createdAt, DateTime(2025, 12, 28, 12, 3, 40));
      expect(
        record.stateOf(DerivativeKind.original).destinationKey,
        startsWith('photos-vault/originals/20251228120340_'),
      );
      expect(
        record.stateOf(DerivativeKind.thumbnail).destinationKey,
        isNotNull,
      );
    });

    test(
      'a v2 carrier with our salt is renamed so its album finds it',
      () async {
        bucket.objects['photos-vault/originals/odd.jpg'] = carrier(
          salt: knownSalt,
        );
        await relist();
        final item = (await BucketFlags(store: store).detect()).single;

        final result = await fixer().rename(item);

        expect(result.outcome, FixOutcome.keptHidden);
        final name = bucket.objects.keys.single.split('/').last;
        expect(nameBelongsTo(name, keys.macKey), isTrue);
        expect(await store.listAll(), isEmpty, reason: 'nothing shown');
      },
    );

    test('a carrier with a foreign salt is left alone', () async {
      bucket.objects['photos-vault/originals/odd.jpg'] = carrier(
        salt: Uint8List(16),
      );
      await relist();
      final item = (await BucketFlags(store: store).detect()).single;

      final result = await fixer().rename(item);

      expect(result.outcome, FixOutcome.needsAlbum);
      expect(bucket.objects.keys.single, endsWith('odd.jpg'));
      expect(await store.listAll(), isEmpty);
    });

    test('a v1 carrier of ours waits for its album', () async {
      bucket.objects['photos-vault/originals/odd.jpg'] = carrier(
        salt: knownSalt,
        v2: false,
      );
      await relist();
      final item = (await BucketFlags(store: store).detect()).single;

      final result = await fixer().rename(item);

      expect(result.outcome, FixOutcome.needsAlbum);
      expect(bucket.objects.keys.single, endsWith('odd.jpg'));
    });

    test('a failed copy leaves the original where it was', () async {
      bucket.objects['photos-vault/originals/odd.mp4'] = video;
      await relist();
      final item = (await BucketFlags(store: store).detect()).single;
      bucket.objects.clear();

      final result = await fixer().rename(item);

      expect(result.outcome, FixOutcome.failed);
    });
  });

  test('import renames every plain flagged file and counts them', () async {
    bucket.objects['photos-vault/originals/import_20251228120340_a.mp4'] =
        video;
    bucket.objects['photos-vault/originals/import_20251228120341_b.mp4'] =
        video;
    final import = BucketImport(
      targetsStore: targets,
      recordStore: store,
      passphrases: () async => [known],
      ops: bucket,
    );

    final result = await import.run();

    expect(result.imported, 2);
    expect(result.left, 0);
    expect(
      bucket.objects.keys.every((k) => fitsProtocol(k.split('/').last)),
      isTrue,
    );
  });

  test('migration renames old backups and repoints the database', () async {
    bucket.objects['photos-vault/originals/photo_A_L0_001.webp'] = video;
    final record = await store.upsert(
      localId: 'photo:A/L0/001',
      contentHash: 'h',
      platform: 'ios',
      createdAt: DateTime(2024, 1, 2, 3, 4, 5),
    );
    const old = 'photos-vault/originals/photo_A_L0_001.webp';
    await store.updateDerivative(
      record.localId,
      DerivativeKind.original,
      const DerivativeState(status: UploadStatus.uploaded, destinationKey: old),
    );
    await store.recordUpload(
      localId: record.localId,
      kind: DerivativeKind.original,
      targetId: target.id,
      destinationKey: old,
      sourceHash: 'src',
    );

    final done = await NameMigration(
      store: store,
      targetsStore: targets,
      ops: bucket,
    ).run();

    expect(done, 1);
    expect(bucket.objects.containsKey(old), isFalse);
    final moved = (await store.getByLocalId(record.localId))!
        .stateOf(DerivativeKind.original)
        .destinationKey!;
    expect(bucket.objects.containsKey(moved), isTrue);
    expect(moved, startsWith('photos-vault/originals/20240102030405_'));
    expect(moved, endsWith('.webp'));
    expect(
      await store.targetsHolding(
        record.localId,
        DerivativeKind.original,
        sourceHash: 'src',
      ),
      {target.id: moved},
      reason: 'a rename is not an edit',
    );
  });

  test('migration skips hidden photos and runs out of work', () async {
    await store.upsert(localId: 'h', contentHash: 'h', platform: 'ios');
    await store.setPasscodeHash('h', 'pin');
    await store.updateDerivative(
      'h',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'photos-vault/originals/photo_h.jpg',
      ),
    );

    final migration = NameMigration(
      store: store,
      targetsStore: targets,
      ops: bucket,
    );

    expect(await migration.run(), 0);
  });
}

AssetRecord _record(String id) => AssetRecord(
  localId: id,
  contentHash: 'h',
  platform: 'ios',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

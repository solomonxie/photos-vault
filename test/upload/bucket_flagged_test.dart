import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:photos_vault/upload/bucket_flagged.dart';
import 'package:photos_vault/upload/bucket_import.dart';
import 'package:photos_vault/upload/name_migration.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/upload/s3_uploader.dart';
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

  test('a bucket no longer set up has its listing forgotten', () async {
    bucket.objects['photos-vault/originals/odd.mp4'] = video;
    await relist();
    await store.replaceBucketObjects('removed', [
      BucketObject(
        targetId: 'removed',
        key: 'old/originals/photo_X_L0_001.webp',
        size: 1,
        lastModified: DateTime(2026),
      ),
    ]);

    await BucketIndexer(
      targetsStore: targets,
      recordStore: store,
      ops: bucket,
    ).forgetRemovedBuckets();

    final flagged = await BucketFlags(store: store).detect();
    expect(flagged.map((f) => f.object.targetId), [target.id]);
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

    test('an older upload of a photo backed up under its current name is an '
        'old copy, and goes with its thumbnail', () async {
      const old = 'photos-vault/originals/photo_ABC_L0_001.webp';
      const oldThumb = 'photos-vault/thumbnails/photo_ABC_L0_001.webp';
      const current = 'photos-vault/originals/20260101120000_abc.heic';
      bucket.objects[old] = video;
      bucket.objects[oldThumb] = video;
      bucket.objects[current] = video;
      await relist();
      await store.upsert(
        localId: 'photo:ABC/L0/001',
        contentHash: 'a',
        platform: 'ios',
      );
      await store.updateDerivative(
        'photo:ABC/L0/001',
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: current,
        ),
      );

      final item = (await BucketFlags(store: store).detect()).single;
      expect(item.kind, FlagKind.oldCopy);
      expect(item.likelyDuplicateOf, current);

      expect((await fixer().removeOldCopy(item)).ok, isTrue);
      expect(bucket.objects.keys, [current]);
    });

    test('a file already queued for deletion is not offered', () async {
      const key = 'photos-vault/originals/photo_GONE_L0_001.webp';
      bucket.objects[key] = video;
      await relist();
      await PendingDeletes(store: store)
          .add([PendingDelete(objectKey: key, targetId: target.id)]);

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
      bucket.refuseCopies = true;

      final result = await fixer().rename(item);

      expect(result.outcome, FixOutcome.failed);
      expect(bucket.objects.keys, ['photos-vault/originals/odd.mp4']);
    });

    test('a file already looked at this session still renames', () async {
      bucket.objects['photos-vault/originals/photo_X_L0_001.webp'] = video;
      await relist();
      final item = (await BucketFlags(store: store).detect()).single;
      final f = fixer();
      await f.canReformat(item);
      await f.inspect(item.object);

      expect((await f.rename(item)).ok, isTrue);
    });

    test('a file already gone is nothing left to fix', () async {
      bucket.objects['photos-vault/originals/odd.mp4'] = video;
      await relist();
      final item = (await BucketFlags(store: store).detect()).single;
      bucket.objects.clear();

      expect((await fixer().rename(item)).ok, isTrue);
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

  test(
    'a key under a retired prefix is re-pointed at the live object',
    () async {
      bucket.objects['photos-vault/originals/photo_A_L0_001.webp'] = video;
      await relist();
      await store.upsert(localId: 'a', contentHash: 'a', platform: 'ios');
      const dead = 'photos-vault2/originals/photo_A_L0_001.webp';
      await store.updateDerivative(
        'a',
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: dead,
        ),
      );
      await store.recordUpload(
        localId: 'a',
        kind: DerivativeKind.original,
        targetId: target.id,
        destinationKey: dead,
      );

      final healed = await NameMigration(
        store: store,
        targetsStore: targets,
        ops: bucket,
      ).healPrefixes();

      expect(healed, 1);
      expect(
        (await store.getByLocalId('a'))!
            .stateOf(DerivativeKind.original)
            .destinationKey,
        'photos-vault/originals/photo_A_L0_001.webp',
      );
      expect(
        await BucketFlags(store: store).detect(),
        isEmpty,
        reason: 'the object is now known, so it is not flagged either',
      );
    },
  );

  test('a key with no live object under this prefix is left alone', () async {
    await relist();
    await store.upsert(localId: 'a', contentHash: 'a', platform: 'ios');
    const dead = 'photos-vault2/originals/photo_gone.webp';
    await store.updateDerivative(
      'a',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: dead,
      ),
    );

    expect(
      await NameMigration(
        store: store,
        targetsStore: targets,
        ops: bucket,
      ).healPrefixes(),
      0,
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

  test(
    'byte-identical copies are duplicates; the one a record uses is kept',
    () async {
      const kept = 'photos-vault/originals/20260101120000_abc.jpg';
      const copy = 'photos-vault/originals/IMG_0042.jpg';
      const sameSizeOther = 'photos-vault/originals/IMG_0043.jpg';
      bucket.objects[kept] = video;
      bucket.objects[copy] = Uint8List.fromList(video);
      bucket.objects[sameSizeOther] = Uint8List.fromList(
        List.generate(video.length, (i) => (i * 7) % 251),
      );
      await relist();
      await store.upsert(localId: 'a', contentHash: 'a', platform: 'ios');
      await store.updateDerivative(
        'a',
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: kept,
        ),
      );
      final f = fixer();

      final flagged = await BucketFlags(store: store)
          .detect(inspect: f.inspect, etag: f.etagOf);
      final dup = flagged.singleWhere((o) => o.kind == FlagKind.duplicate);

      expect(dup.object.key, copy);
      expect(dup.likelyDuplicateOf, kept);
      expect((await f.removeOldCopy(dup)).ok, isTrue);
      expect(bucket.objects.containsKey(copy), isFalse);
      expect(bucket.objects.containsKey(kept), isTrue);
    },
  );

  test(
    'optimizing in the bucket swaps the copy there and keeps the hash',
    () async {
      const oldKey = 'photos-vault/originals/20260101120000_abc.jpg';
      bucket.objects[oldKey] = video;
      await store.upsert(localId: 'a', contentHash: 'a', platform: 'ios');
      await store.updateDerivative(
        'a',
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: oldKey,
          backedUpHash: 'local-hash',
        ),
      );
      await store.recordUpload(
        localId: 'a',
        kind: DerivativeKind.original,
        targetId: target.id,
        destinationKey: oldKey,
        sourceHash: 'local-hash',
      );
      final smaller = File('${Directory.systemTemp.path}/pv_small.heic')
        ..writeAsBytesSync([1, 2, 3]);
      addTearDown(() => smaller.deleteSync());

      final result = await BucketFixer(
        store: store,
        targetsStore: targets,
        passphrases: () async => const [],
        ops: bucket,
        uploader: _BucketUploader(bucket),
      ).replaceRemoteOriginal((await store.getByLocalId('a'))!, smaller);

      expect(result.ok, isTrue);
      const newKey = 'photos-vault/originals/20260101120000_abc.heic';
      expect(bucket.objects.keys, [newKey]);
      final state = (await store.getByLocalId('a'))!
          .stateOf(DerivativeKind.original);
      expect(state.destinationKey, newKey);
      expect(state.backedUpHash, 'local-hash');
      expect(
        await store.targetsHolding(
          'a',
          DerivativeKind.original,
          sourceHash: 'local-hash',
        ),
        {target.id: newKey},
      );
    },
  );
}

AssetRecord _record(String id) => AssetRecord(
  localId: id,
  contentHash: 'h',
  platform: 'ios',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

class _BucketUploader implements S3Uploader {
  _BucketUploader(this.bucket);
  final MemoryBucket bucket;

  @override
  Future<bool> put({
    required String filePath,
    required String key,
    required S3BackupTarget target,
  }) async {
    bucket.objects[key] = File(filePath).readAsBytesSync();
    return true;
  }
}

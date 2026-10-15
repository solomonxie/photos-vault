import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:photos_vault/upload/bucket_flagged.dart';
import 'package:photos_vault/upload/bucket_ops.dart';
import 'package:photos_vault/upload/name_migration.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/upload/s3_uploader.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/carrier_probe.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../settings/fake_secure_store.dart';
import '../support/memory_bucket.dart';
import '../vault/carrier_fixtures.dart';

/// The guard against the real SQL store: what `keyHeldByOthers` and the
/// listing really answer, not what a fake says they would.
void main() {
  setUpAll(sqfliteFfiInit);

  late AssetRecordStore store;
  late BackupTargetsStore targets;
  late S3BackupTarget target;
  late MemoryBucket bucket;

  final bytes = Uint8List.fromList(List.generate(4000, (i) => i % 251));
  final smaller = Uint8List.fromList(List.generate(900, (i) => i % 13));

  Uint8List carrier() => buildJpegCarrier(
    cipher: PlatformCipher(),
    keys: CarrierKeys.forAlbum(Uint8List.fromList(List.generate(32, (i) => i))),
    masterSalt: Uint8List.fromList(List.generate(16, (i) => i * 3)),
    decoy: decoyJpeg(),
    thumbnail: Uint8List.fromList(List.generate(3000, (i) => i % 200)),
    original: Uint8List.fromList(List.generate(20000, (i) => i % 250)),
    extension: 'jpg',
    nonce: Uint8List.fromList(List.generate(8, (i) => i + 9)),
    meta: CarrierMeta(
      takenAt: DateTime(2024, 5, 6),
      width: 10,
      height: 20,
      isVideo: false,
    ),
  )!;

  Future<void> list(S3BackupTarget t, {DateTime? at}) =>
      store.replaceBucketObjects(t.id, [
        for (final e in bucket.objects.entries)
          if (e.key.startsWith(t.prefix))
            BucketObject(
              targetId: t.id,
              key: e.key,
              size: e.value.length,
              lastModified: at ?? DateTime(2026, 1, 1),
            ),
      ]);

  Future<void> hold(String localId, String key, {DerivativeKind? kind}) async {
    final k = kind ?? DerivativeKind.original;
    await store.upsert(localId: localId, contentHash: localId, platform: 'ios');
    await store.updateDerivative(
      localId,
      k,
      DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
    );
    await store.recordUpload(
      localId: localId,
      kind: k,
      targetId: target.id,
      destinationKey: key,
    );
  }

  Future<DeleteOutcome> guard(
    String key, {
    Keeper? keep,
    bool carrierProof = false,
    BucketOps? ops,
  }) => (ops ?? bucket).deleteGuarded(
    target,
    key,
    store: store,
    keep: keep,
    carrierProof: carrierProof,
  );

  setUp(() async {
    store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    targets = BackupTargetsStore(store: FakeSecureStore());
    target = await targets.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'b',
      prefix: 'pv/',
    );
    bucket = MemoryBucket();
  });

  group('deleteGuarded', () {
    test('a key a record holds is refused, by row or by column', () async {
      bucket.objects['pv/originals/a.jpg'] = bytes;
      bucket.objects['pv/thumbnails/b.jpg'] = bytes;
      await hold('photo:a', 'pv/originals/a.jpg');
      await store.upsert(localId: 'photo:b', contentHash: 'b', platform: 'ios');
      await store.updateDerivative(
        'photo:b',
        DerivativeKind.thumbnail,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'pv/thumbnails/b.jpg',
        ),
      );

      expect(await guard('pv/originals/a.jpg'), DeleteOutcome.held);
      expect(await guard('pv/thumbnails/b.jpg'), DeleteOutcome.held);
      expect(
        await guard('pv/originals/a.jpg', carrierProof: true),
        DeleteOutcome.held,
        reason: 'not even the vault deletes what a photo uses',
      );
      expect(bucket.deleted, isEmpty);
    });

    test('a carrier is refused unless the vault retires it', () async {
      bucket.objects['pv/originals/c.jpg'] = carrier();

      expect(await guard('pv/originals/c.jpg'), DeleteOutcome.carrier);
      expect(bucket.objects, contains('pv/originals/c.jpg'));

      expect(
        await guard('pv/originals/c.jpg', carrierProof: true),
        DeleteOutcome.deleted,
      );
    });

    test('a keeper that is missing refuses the delete', () async {
      bucket.objects['pv/originals/old.jpg'] = bytes;

      expect(
        await guard(
          'pv/originals/old.jpg',
          keep: const Keeper('pv/originals/new.jpg'),
        ),
        DeleteOutcome.keeperUnproven,
      );
      expect(bucket.deleted, isEmpty);
    });

    test('a keeper proven live lets it go, and out of the listing', () async {
      bucket.objects['pv/originals/old.jpg'] = bytes;
      bucket.objects['pv/originals/new.jpg'] = bytes;
      await list(target);

      expect(
        await guard(
          'pv/originals/old.jpg',
          keep: const Keeper('pv/originals/new.jpg', sameBytes: true),
        ),
        DeleteOutcome.deleted,
      );
      expect(bucket.deleted, ['pv/originals/old.jpg']);
      expect((await store.listBucketObjects()).map((o) => o.key), [
        'pv/originals/new.jpg',
      ]);
    });

    test('a smaller keeper never retires a larger old copy', () async {
      bucket.objects['pv/originals/x.jpg'] = bytes;
      bucket.objects['pv/originals/x.heif'] = smaller;

      expect(
        await guard(
          'pv/originals/x.jpg',
          keep: const Keeper('pv/originals/x.heif', notSmaller: true),
        ),
        DeleteOutcome.keeperUnproven,
      );
      expect(
        await guard(
          'pv/originals/x.jpg',
          keep: const Keeper('pv/originals/x.heif', size: 1),
        ),
        DeleteOutcome.keeperUnproven,
      );
      expect(bucket.deleted, isEmpty);
    });

    test('an unanswered HEAD or header read never deletes', () async {
      bucket.objects['pv/originals/a.jpg'] = bytes;
      bucket.silent.add('pv/originals/a.jpg');
      expect(await guard('pv/originals/a.jpg'), DeleteOutcome.unknown);

      final unreadable = _UnreadableBucket()
        ..objects['pv/originals/b.jpg'] = bytes;
      expect(
        await guard('pv/originals/b.jpg', ops: unreadable),
        DeleteOutcome.unknown,
      );

      bucket.objects['pv/originals/k.jpg'] = bytes;
      bucket.silent.add('pv/originals/keep.jpg');
      expect(
        await guard(
          'pv/originals/k.jpg',
          keep: const Keeper('pv/originals/keep.jpg'),
        ),
        DeleteOutcome.unknown,
      );
      expect(bucket.deleted, isEmpty);
      expect(unreadable.deleted, isEmpty);
    });

    test('a 404 is gone, without a DELETE, and leaves the listing', () async {
      await store.replaceBucketObjects(target.id, [
        BucketObject(
          targetId: target.id,
          key: 'pv/originals/z.jpg',
          size: 1,
          lastModified: DateTime(2026),
        ),
      ]);
      expect(await guard('pv/originals/z.jpg'), DeleteOutcome.gone);
      expect(bucket.deleted, isEmpty);
      expect(await store.listBucketObjects(), isEmpty);
    });
  });

  group('PendingDeletes through the guard', () {
    test('a carrier the vault did not retire is dropped, never deleted; an '
        'unanswered one waits', () async {
      bucket.objects['pv/originals/c.jpg'] = carrier();
      bucket.objects['pv/originals/v.jpg'] = carrier();
      bucket.objects['pv/originals/s.jpg'] = bytes;
      bucket.silent.add('pv/originals/s.jpg');
      final deletes = PendingDeletes(store: store, ops: bucket);
      await deletes.add([
        PendingDelete(objectKey: 'pv/originals/c.jpg', targetId: target.id),
        PendingDelete(
          objectKey: 'pv/originals/v.jpg',
          targetId: target.id,
          carrier: true,
        ),
        PendingDelete(objectKey: 'pv/originals/s.jpg', targetId: target.id),
      ]);

      expect(await deletes.drain([target]), 1);
      expect(bucket.deleted, ['pv/originals/v.jpg']);
      expect(bucket.objects, contains('pv/originals/c.jpg'));
      expect((await deletes.pending()).single.objectKey, 'pv/originals/s.jpg');
    });

    test('a key a photo came to hold is dropped, not deleted', () async {
      bucket.objects['pv/originals/a.jpg'] = bytes;
      final deletes = PendingDeletes(store: store, ops: bucket);
      await deletes.add([
        PendingDelete(objectKey: 'pv/originals/a.jpg', targetId: target.id),
      ]);
      await hold('photo:other', 'pv/originals/a.jpg');

      expect(await deletes.drain([target]), 0);
      expect(bucket.deleted, isEmpty);
    });
  });

  group('probes that feed a fix', () {
    BucketFixer fixer({BucketOps? ops, S3Uploader? uploader}) => BucketFixer(
      store: store,
      targetsStore: targets,
      passphrases: () async => const <PassphraseEntry>[],
      ops: ops ?? bucket,
      uploader: uploader,
    );
    FlaggedObject flagged(String key, FlagKind kind, {String? keep}) =>
        FlaggedObject(
          object: BucketObject(
            targetId: target.id,
            key: key,
            size: bytes.length,
            lastModified: DateTime(2026),
          ),
          kind: kind,
          likelyDuplicateOf: keep,
        );

    test('rename with an unreadable header neither renames nor imports '
        'nor deletes', () async {
      final unreadable = _UnreadableBucket()
        ..objects['pv/originals/IMG_1.jpg'] = bytes;

      final result = await fixer(ops: unreadable)
          .rename(flagged('pv/originals/IMG_1.jpg', FlagKind.offProtocol));

      expect(result.ok, isFalse);
      expect(unreadable.objects.keys, ['pv/originals/IMG_1.jpg']);
      expect(await store.listAll(), isEmpty);
    });

    test('adopt with no answer from the bucket is a failure, not '
        '"removed"', () async {
      bucket.objects['pv/originals/20260101120000_${'a' * 32}.jpg'] = bytes;
      bucket.silent.add('pv/originals/20260101120000_${'a' * 32}.jpg');

      final result = await fixer().adopt(
        flagged(
          'pv/originals/20260101120000_${'a' * 32}.jpg',
          FlagKind.unclaimed,
        ),
      );

      expect(result.outcome, FixOutcome.failed);
      expect(await store.listAll(), isEmpty);
    });

    test('liveOriginal with no bucket to ask is never "not there"', () async {
      final none = BackupTargetsStore(store: FakeSecureStore());
      final f = BucketFixer(
        store: store,
        targetsStore: none,
        passphrases: () async => const <PassphraseEntry>[],
        ops: bucket,
      );
      await expectLater(f.liveOriginal('x', false), throwsStateError);
    });

    test('an old copy whose keeper is smaller is left alone', () async {
      bucket.objects['pv/originals/x.HEIC'] = bytes;
      bucket.objects['pv/originals/x.heif'] = smaller;
      await hold('photo:x', 'pv/originals/x.heif');

      final result = await fixer().removeOldCopy(
        flagged(
          'pv/originals/x.HEIC',
          FlagKind.oldCopy,
          keep: 'pv/originals/x.heif',
        ),
      );

      expect(result.ok, isFalse);
      expect(bucket.deleted, isEmpty);
    });

    test('replaceRemoteOriginal: one bucket failing deletes nothing and '
        'moves no row', () async {
      final second = await targets.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'b2',
        prefix: 'pv2/',
      );
      const oldA = 'pv/originals/20260101120000_abc.jpg';
      const oldB = 'pv2/originals/20260101120000_abc.jpg';
      bucket.objects[oldA] = bytes;
      bucket.objects[oldB] = bytes;
      await hold('photo:a', oldA);
      await store.recordUpload(
        localId: 'photo:a',
        kind: DerivativeKind.original,
        targetId: second.id,
        destinationKey: oldB,
      );
      final file = File('${Directory.systemTemp.path}/pv_guard_small.heif')
        ..writeAsBytesSync(smaller);
      addTearDown(() => file.deleteSync());

      final result = await fixer(uploader: _FailingFor(bucket, second.id))
          .replaceRemoteOriginal((await store.getByLocalId('photo:a'))!, file);

      expect(result.ok, isFalse);
      expect(bucket.objects.keys, unorderedEquals([oldA, oldB]));
      expect(
        (await store.getByLocalId('photo:a'))!
            .stateOf(DerivativeKind.original)
            .destinationKey,
        oldA,
      );
      expect(await store.targetsHolding('photo:a', DerivativeKind.original), {
        target.id: oldA,
        second.id: oldB,
      });
    });
  });

  group('healPrefixes', () {
    NameMigration migration() =>
        NameMigration(store: store, targetsStore: targets, ops: bucket);

    test('never onto another format older than the upload', () async {
      bucket.objects['pv/originals/X.HEIC'] = bytes;
      await list(target, at: DateTime(2020));
      await hold('photo:x', 'old/originals/X.jpg');

      expect(await migration().healPrefixes(), 0);
    });

    test('never re-points a Live Photo motion key at its still', () async {
      bucket.objects['pv/originals/X.HEIC'] = bytes;
      // Newer than the upload, so only the kind can refuse it.
      await list(target, at: DateTime.now().add(const Duration(days: 1)));
      await hold(
        'photo:x',
        'old/originals/X.mov',
        kind: DerivativeKind.livePhoto,
      );

      expect(await migration().healPrefixes(), 0);
      expect(
        (await store.getByLocalId('photo:x'))!
            .stateOf(DerivativeKind.livePhoto)
            .destinationKey,
        'old/originals/X.mov',
      );
    });

    test('a key the listing missed but the bucket still has stays', () async {
      bucket.objects['old/originals/X.jpg'] = bytes;
      bucket.objects['pv/originals/X.jpg'] = bytes;
      await list(target);
      await hold('photo:x', 'old/originals/X.jpg');

      expect(await migration().healPrefixes(), 0);
    });

    test('a dead key moves to the live one of its own kind', () async {
      bucket.objects['pv/originals/X.jpg'] = bytes;
      await list(target);
      await hold('photo:x', 'old/originals/X.jpg');

      expect(await migration().healPrefixes(), 1);
      expect(await store.targetsHolding('photo:x', DerivativeKind.original), {
        target.id: 'pv/originals/X.jpg',
      });
    });
  });
}

/// Answers HEAD, but every ranged read fails.
class _UnreadableBucket extends MemoryBucket {
  @override
  RangeReader rangeReader(S3BackupTarget target, String key) =>
      (start, end) async => null;
}

/// Puts into [bucket], except for one bucket's target, which fails.
class _FailingFor implements S3Uploader {
  _FailingFor(this.bucket, this.failingTarget);
  final MemoryBucket bucket;
  final String failingTarget;

  @override
  Future<bool> put({
    required String filePath,
    required String key,
    required S3BackupTarget target,
  }) async {
    if (target.id == failingTarget) return false;
    bucket.objects[key] = File(filePath).readAsBytesSync();
    return true;
  }
}

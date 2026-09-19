import 'dart:io';

import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/upload/backup_cancel_token.dart';
import 'package:photos_vault/upload/backup_coordinator.dart';
import 'package:photos_vault/upload/s3_uploader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../settings/fake_secure_store.dart';

class _FakeS3Uploader implements S3Uploader {
  _FakeS3Uploader(this.result);
  final bool result;
  final keys = <String>[];

  @override
  Future<bool> put({
    required String filePath,
    required String key,
    required S3BackupTarget target,
  }) async {
    keys.add(key);
    return result;
  }
}

/// Records the (filePath, key, target) of every call, in order — used
/// where a test needs to assert the order attempts happened in, not just
/// which keys were uploaded.
class _RecordingS3Uploader implements S3Uploader {
  _RecordingS3Uploader(this._resultFor);
  final bool Function(String filePath, String key, S3BackupTarget target)
  _resultFor;

  @override
  Future<bool> put({
    required String filePath,
    required String key,
    required S3BackupTarget target,
  }) async {
    return _resultFor(filePath, key, target);
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  // sqflite_common_ffi caches in-memory DBs by path (singleInstance
  // default), so distinct stores using the same sentinel path leak state
  // across tests unless each is explicitly closed.
  AssetRecordStore newRecordStore() {
    final store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return store;
  }

  Future<BackupTargetsStore> oneTarget({
    BackupFormat format = BackupFormat.original,
  }) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    await targetsStore.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'bucket',
      prefix: '',
    );
    await targetsStore.setBackupFormat(format);
    return targetsStore;
  }

  group('Live Photos', () {
    test(
      'the moving half lands beside the still, not in its own folder',
      () async {
        final recordStore = newRecordStore();
        final record = await recordStore.upsert(
          localId: 'photo:live',
          contentHash: 'l',
          platform: 'ios',
          isLivePhoto: true,
        );
        final keys = <String>[];
        final coordinator = BackupCoordinator(
          targetsStore: await oneTarget(),
          recordStore: recordStore,
          s3Uploader: _RecordingS3Uploader((path, key, target) {
            keys.add(key);
            return true;
          }),
          hashFile: (_) async => 'hash',
        );

        await coordinator.backUpDerivative(
          record: record,
          kind: DerivativeKind.original,
          filePath: '/tmp/IMG.HEIC',
        );
        await coordinator.backUpDerivative(
          record: record,
          kind: DerivativeKind.livePhoto,
          filePath: '/tmp/IMG.mov',
        );

        // Same prefix, same base name, differing only by extension — a
        // bucket listing shows them as the pair they are.
        expect(keys, ['originals/photo_live.HEIC', 'originals/photo_live.mov']);
      },
    );

    test('the .mov is never re-encoded, whatever the format says', () async {
      final recordStore = newRecordStore();
      final record = await recordStore.upsert(
        localId: 'photo:live',
        contentHash: 'l',
        platform: 'ios',
        isLivePhoto: true,
      );
      final keys = <String>[];

      await BackupCoordinator(
        targetsStore: await oneTarget(format: BackupFormat.optimized),
        recordStore: recordStore,
        s3Uploader: _RecordingS3Uploader((path, key, target) {
          keys.add(key);
          return true;
        }),
        hashFile: (_) async => 'hash',
      ).backUpDerivative(
        record: record,
        kind: DerivativeKind.livePhoto,
        filePath: '/tmp/IMG.mov',
      );

      // A WebP encoder would strip the QuickTime metadata that pairs the
      // two halves, leaving a still with a video next to it.
      expect(keys.single, endsWith('.mov'));
    });

    test('a still-only backup is not a backed-up Live Photo', () async {
      final recordStore = newRecordStore();
      await recordStore.upsert(
        localId: 'photo:live',
        contentHash: 'l',
        platform: 'ios',
        isLivePhoto: true,
      );
      await recordStore.updateDerivative(
        'photo:live',
        DerivativeKind.original,
        const DerivativeState(status: UploadStatus.uploaded),
      );

      final half = (await recordStore.getByLocalId('photo:live'))!;
      expect(half.isFullyBackedUp, isFalse, reason: 'the motion is missing');

      await recordStore.updateDerivative(
        'photo:live',
        DerivativeKind.livePhoto,
        const DerivativeState(status: UploadStatus.uploaded),
      );

      expect(
        (await recordStore.getByLocalId('photo:live'))!.isFullyBackedUp,
        isTrue,
      );
    });

    test('a plain photo needs only its original', () async {
      final recordStore = newRecordStore();
      await recordStore.upsert(
        localId: 'manual:a',
        contentHash: 'a',
        platform: 'ios',
      );
      await recordStore.updateDerivative(
        'manual:a',
        DerivativeKind.original,
        const DerivativeState(status: UploadStatus.uploaded),
      );

      expect(
        (await recordStore.getByLocalId('manual:a'))!.isFullyBackedUp,
        isTrue,
      );
    });
  });

  test('with no configured targets, status stays pending', () async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = newRecordStore();
    final record = await recordStore.upsert(
      localId: 'manual:abc',
      contentHash: 'abc',
      platform: 'ios',
    );
    final coordinator = BackupCoordinator(
      targetsStore: targetsStore,
      recordStore: recordStore,
    );

    final succeeded = await coordinator.backUpDerivative(
      record: record,
      kind: DerivativeKind.original,
      filePath: '/tmp/a.jpg',
    );

    expect(succeeded, 0);
    final updated = await recordStore.getByLocalId('manual:abc');
    expect(
      updated!.stateOf(DerivativeKind.original).status,
      UploadStatus.pending,
    );
  });

  test('uploads to an S3 target and marks the derivative uploaded', () async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    await targetsStore.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'bucket',
      prefix: 'p/',
    );
    final recordStore = newRecordStore();
    final record = await recordStore.upsert(
      localId: 'manual:abc',
      contentHash: 'abc',
      platform: 'ios',
    );
    final fakeUploader = _FakeS3Uploader(true);
    final coordinator = BackupCoordinator(
      targetsStore: targetsStore,
      recordStore: recordStore,
      s3Uploader: fakeUploader,
    );

    final succeeded = await coordinator.backUpDerivative(
      record: record,
      kind: DerivativeKind.original,
      filePath: '/tmp/a.jpg',
    );

    expect(succeeded, 1);
    expect(fakeUploader.keys.single, 'p/originals/manual_abc.jpg');
    final updated = await recordStore.getByLocalId('manual:abc');
    expect(
      updated!.stateOf(DerivativeKind.original).status,
      UploadStatus.uploaded,
    );
    expect(
      updated.stateOf(DerivativeKind.original).destinationKey,
      'p/originals/manual_abc.jpg',
    );
  });

  test('marks the derivative failed when every target fails', () async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    await targetsStore.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'bucket',
      prefix: '',
    );
    final recordStore = newRecordStore();
    final record = await recordStore.upsert(
      localId: 'manual:abc',
      contentHash: 'abc',
      platform: 'ios',
    );
    final coordinator = BackupCoordinator(
      targetsStore: targetsStore,
      recordStore: recordStore,
      s3Uploader: _FakeS3Uploader(false),
    );

    final succeeded = await coordinator.backUpDerivative(
      record: record,
      kind: DerivativeKind.original,
      filePath: '/tmp/a.jpg',
    );

    expect(succeeded, 0);
    final updated = await recordStore.getByLocalId('manual:abc');
    expect(
      updated!.stateOf(DerivativeKind.original).status,
      UploadStatus.failed,
    );
  });

  test(
    'a thumbnail derivative lands under thumbnails/, not originals/',
    () async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'bucket',
        prefix: 'p/',
      );
      final recordStore = newRecordStore();
      final record = await recordStore.upsert(
        localId: 'manual:abc',
        contentHash: 'abc',
        platform: 'ios',
      );
      final fakeUploader = _FakeS3Uploader(true);
      final coordinator = BackupCoordinator(
        targetsStore: targetsStore,
        recordStore: recordStore,
        s3Uploader: fakeUploader,
        hashFile: (path) async => 'hash',
      );

      await coordinator.backUpDerivative(
        record: record,
        kind: DerivativeKind.thumbnail,
        filePath: '/tmp/a-thumb.jpg',
      );

      expect(fakeUploader.keys.single, 'p/thumbnails/manual_abc.jpg');
      final updated = await recordStore.getByLocalId('manual:abc');
      expect(
        updated!.stateOf(DerivativeKind.thumbnail).status,
        UploadStatus.uploaded,
      );
      // The original is tracked independently and hasn't been touched.
      expect(
        updated.stateOf(DerivativeKind.original).status,
        UploadStatus.pending,
      );
    },
  );

  group('backedUpHash', () {
    test('set to the hashed local file once an upload succeeds', () async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'bucket',
        prefix: '',
      );
      final recordStore = newRecordStore();
      final record = await recordStore.upsert(
        localId: 'manual:abc',
        contentHash: 'abc',
        platform: 'ios',
      );
      final coordinator = BackupCoordinator(
        targetsStore: targetsStore,
        recordStore: recordStore,
        s3Uploader: _FakeS3Uploader(true),
        hashFile: (path) async => 'hash-of-$path',
      );

      await coordinator.backUpDerivative(
        record: record,
        kind: DerivativeKind.original,
        filePath: '/tmp/a.jpg',
      );

      final updated = await recordStore.getByLocalId('manual:abc');
      expect(
        updated!.stateOf(DerivativeKind.original).backedUpHash,
        'hash-of-/tmp/a.jpg',
      );
    });

    test('kept as-is when every target fails, rather than cleared', () async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'bucket',
        prefix: '',
      );
      final recordStore = newRecordStore();
      await recordStore.upsert(
        localId: 'manual:abc',
        contentHash: 'abc',
        platform: 'ios',
      );
      await recordStore.updateDerivative(
        'manual:abc',
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          backedUpHash: 'previous-hash',
        ),
      );
      final staleRecord = (await recordStore.getByLocalId('manual:abc'))!;
      final coordinator = BackupCoordinator(
        targetsStore: targetsStore,
        recordStore: recordStore,
        s3Uploader: _FakeS3Uploader(false),
        hashFile: (path) async => 'new-hash',
      );

      await coordinator.backUpDerivative(
        record: staleRecord,
        kind: DerivativeKind.original,
        filePath: '/tmp/a.jpg',
      );

      final updated = await recordStore.getByLocalId('manual:abc');
      expect(
        updated!.stateOf(DerivativeKind.original).status,
        UploadStatus.failed,
      );
      expect(
        updated.stateOf(DerivativeKind.original).backedUpHash,
        'previous-hash',
      );
    });

    test(
      'a hashing failure does not stop the derivative being marked uploaded',
      () async {
        final targetsStore = BackupTargetsStore(store: FakeSecureStore());
        await targetsStore.add(
          accessKeyId: 'a',
          secretAccessKey: 'b',
          region: 'us-east-1',
          bucket: 'bucket',
          prefix: '',
        );
        final recordStore = newRecordStore();
        final record = await recordStore.upsert(
          localId: 'manual:abc',
          contentHash: 'abc',
          platform: 'ios',
        );
        final coordinator = BackupCoordinator(
          targetsStore: targetsStore,
          recordStore: recordStore,
          s3Uploader: _FakeS3Uploader(true),
          hashFile: (path) async => throw Exception('disk error'),
        );

        final succeeded = await coordinator.backUpDerivative(
          record: record,
          kind: DerivativeKind.original,
          filePath: '/tmp/a.jpg',
        );

        expect(succeeded, 1);
        final updated = await recordStore.getByLocalId('manual:abc');
        expect(
          updated!.stateOf(DerivativeKind.original).status,
          UploadStatus.uploaded,
        );
        expect(updated.stateOf(DerivativeKind.original).backedUpHash, isNull);
      },
    );
  });

  group('backUpBatch', () {
    test('fileByFile (default) mirrors each record to every target', () async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'one',
        prefix: '',
      );
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'two',
        prefix: '',
      );
      final recordStore = newRecordStore();
      final a = await recordStore.upsert(
        localId: 'manual:a',
        contentHash: 'a',
        platform: 'ios',
      );
      final b = await recordStore.upsert(
        localId: 'manual:b',
        contentHash: 'b',
        platform: 'ios',
      );
      final fakeUploader = _FakeS3Uploader(true);
      final coordinator = BackupCoordinator(
        targetsStore: targetsStore,
        recordStore: recordStore,
        s3Uploader: fakeUploader,
      );

      final succeeded = await coordinator.backUpBatch(
        records: [a, b],
        kind: DerivativeKind.original,
        resolvePath: (r) async => '/tmp/${r.localId}.jpg',
      );

      expect(succeeded, 2);
      // Every record's pair of targets uploaded before moving to the next
      // record: a→one, a→two, b→one, b→two.
      expect(fakeUploader.keys, [
        'originals/manual_a.jpg',
        'originals/manual_a.jpg',
        'originals/manual_b.jpg',
        'originals/manual_b.jpg',
      ]);
      expect(
        (await recordStore.getByLocalId('manual:a'))!
            .stateOf(DerivativeKind.original)
            .status,
        UploadStatus.uploaded,
      );
      expect(
        (await recordStore.getByLocalId('manual:b'))!
            .stateOf(DerivativeKind.original)
            .status,
        UploadStatus.uploaded,
      );
    });

    test(
      'bucketByBucket finishes every record against one target before the next',
      () async {
        final targetsStore = BackupTargetsStore(store: FakeSecureStore());
        await targetsStore.add(
          accessKeyId: 'a',
          secretAccessKey: 'b',
          region: 'us-east-1',
          bucket: 'one',
          prefix: '',
        );
        await targetsStore.add(
          accessKeyId: 'a',
          secretAccessKey: 'b',
          region: 'us-east-1',
          bucket: 'two',
          prefix: '',
        );
        await targetsStore.setOrderStrategy(BackupOrderStrategy.bucketByBucket);
        final recordStore = newRecordStore();
        final a = await recordStore.upsert(
          localId: 'manual:a',
          contentHash: 'a',
          platform: 'ios',
        );
        final b = await recordStore.upsert(
          localId: 'manual:b',
          contentHash: 'b',
          platform: 'ios',
        );
        final callOrder = <String>[];
        final fakeUploader = _RecordingS3Uploader((filePath, key, target) {
          callOrder.add('$filePath -> ${target.bucket}');
          return true;
        });
        final coordinator = BackupCoordinator(
          targetsStore: targetsStore,
          recordStore: recordStore,
          s3Uploader: fakeUploader,
        );

        final succeeded = await coordinator.backUpBatch(
          records: [a, b],
          kind: DerivativeKind.original,
          resolvePath: (r) async => '/tmp/${r.localId}.jpg',
        );

        expect(succeeded, 2);
        // Every record against "one" before either is tried against "two".
        expect(callOrder, [
          '/tmp/manual:a.jpg -> one',
          '/tmp/manual:b.jpg -> one',
          '/tmp/manual:a.jpg -> two',
          '/tmp/manual:b.jpg -> two',
        ]);
        expect(
          (await recordStore.getByLocalId('manual:a'))!
              .stateOf(DerivativeKind.original)
              .status,
          UploadStatus.uploaded,
        );
        expect(
          (await recordStore.getByLocalId('manual:b'))!
              .stateOf(DerivativeKind.original)
              .status,
          UploadStatus.uploaded,
        );
      },
    );

    test('bucketByBucket still marks a record uploaded if only one target succeeds', () async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'good',
        prefix: '',
      );
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'bad',
        prefix: '',
      );
      await targetsStore.setOrderStrategy(BackupOrderStrategy.bucketByBucket);
      final recordStore = newRecordStore();
      final a = await recordStore.upsert(
        localId: 'manual:a',
        contentHash: 'a',
        platform: 'ios',
      );
      final fakeUploader = _RecordingS3Uploader(
        (filePath, key, target) => target.bucket == 'good',
      );
      final coordinator = BackupCoordinator(
        targetsStore: targetsStore,
        recordStore: recordStore,
        s3Uploader: fakeUploader,
      );

      final succeeded = await coordinator.backUpBatch(
        records: [a],
        kind: DerivativeKind.original,
        resolvePath: (r) async => '/tmp/${r.localId}.jpg',
      );

      expect(succeeded, 1);
      expect(
        (await recordStore.getByLocalId('manual:a'))!
            .stateOf(DerivativeKind.original)
            .status,
        UploadStatus.uploaded,
      );
    });

    test('skips a record whose path fails to resolve', () async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'one',
        prefix: '',
      );
      final recordStore = newRecordStore();
      final a = await recordStore.upsert(
        localId: 'manual:a',
        contentHash: 'a',
        platform: 'ios',
      );
      final coordinator = BackupCoordinator(
        targetsStore: targetsStore,
        recordStore: recordStore,
        s3Uploader: _FakeS3Uploader(true),
      );

      final succeeded = await coordinator.backUpBatch(
        records: [a],
        kind: DerivativeKind.original,
        resolvePath: (r) async => throw Exception('iCloud fetch failed'),
      );

      expect(succeeded, 0);
      expect(
        (await recordStore.getByLocalId('manual:a'))!
            .stateOf(DerivativeKind.original)
            .status,
        UploadStatus.pending,
      );
    });
  });

  group('cancelToken', () {
    test(
      'fileByFile: cancelling mid-run leaves un-attempted records untouched',
      () async {
        final targetsStore = BackupTargetsStore(store: FakeSecureStore());
        await targetsStore.add(
          accessKeyId: 'a',
          secretAccessKey: 'b',
          region: 'us-east-1',
          bucket: 'one',
          prefix: '',
        );
        final recordStore = newRecordStore();
        final a = await recordStore.upsert(
          localId: 'manual:a',
          contentHash: 'a',
          platform: 'ios',
        );
        final b = await recordStore.upsert(
          localId: 'manual:b',
          contentHash: 'b',
          platform: 'ios',
        );
        final token = BackupCancelToken();
        final fakeUploader = _RecordingS3Uploader((filePath, key, target) {
          token.cancel(); // cancel as soon as the first upload happens
          return true;
        });
        final coordinator = BackupCoordinator(
          targetsStore: targetsStore,
          recordStore: recordStore,
          s3Uploader: fakeUploader,
        );

        final succeeded = await coordinator.backUpBatch(
          records: [a, b],
          kind: DerivativeKind.original,
          resolvePath: (r) async => '/tmp/${r.localId}.jpg',
          cancelToken: token,
        );

        expect(succeeded, 1);
        expect(
          (await recordStore.getByLocalId('manual:a'))!
              .stateOf(DerivativeKind.original)
              .status,
          UploadStatus.uploaded,
        );
        // "b" was never attempted — still pending, not failed.
        expect(
          (await recordStore.getByLocalId('manual:b'))!
              .stateOf(DerivativeKind.original)
              .status,
          UploadStatus.pending,
        );
      },
    );

    test('bucketByBucket: cancelling mid-run leaves un-attempted records untouched', () async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'one',
        prefix: '',
      );
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'two',
        prefix: '',
      );
      await targetsStore.setOrderStrategy(BackupOrderStrategy.bucketByBucket);
      final recordStore = newRecordStore();
      final a = await recordStore.upsert(
        localId: 'manual:a',
        contentHash: 'a',
        platform: 'ios',
      );
      final b = await recordStore.upsert(
        localId: 'manual:b',
        contentHash: 'b',
        platform: 'ios',
      );
      final token = BackupCancelToken();
      final fakeUploader = _RecordingS3Uploader((filePath, key, target) {
        token.cancel(); // cancel as soon as the very first (record, target) attempt happens
        return true;
      });
      final coordinator = BackupCoordinator(
        targetsStore: targetsStore,
        recordStore: recordStore,
        s3Uploader: fakeUploader,
      );

      final succeeded = await coordinator.backUpBatch(
        records: [a, b],
        kind: DerivativeKind.original,
        resolvePath: (r) async => '/tmp/${r.localId}.jpg',
        cancelToken: token,
      );

      // "a" got exactly one attempt (against "one") before cancellation —
      // that alone is enough to mark it uploaded. "b" never got any
      // attempt at all, so it's left alone rather than reconciled as
      // "failed".
      expect(succeeded, 1);
      expect(
        (await recordStore.getByLocalId('manual:a'))!
            .stateOf(DerivativeKind.original)
            .status,
        UploadStatus.uploaded,
      );
      expect(
        (await recordStore.getByLocalId('manual:b'))!
            .stateOf(DerivativeKind.original)
            .status,
        UploadStatus.pending,
      );
    });
  });

  group('BackupFormat.optimized', () {
    late Directory tempDir;

    setUp(() => tempDir = Directory.systemTemp.createTempSync('byop_test_'));
    tearDown(() => tempDir.delete(recursive: true));

    test('re-encodes a photo to WebP and uploads it under a .webp key', () async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'bucket',
        prefix: '',
      );
      await targetsStore.setBackupFormat(BackupFormat.optimized);
      final recordStore = newRecordStore();
      final record = await recordStore.upsert(
        localId: 'manual:abc',
        contentHash: 'abc',
        platform: 'ios',
      );
      final photoFile = File('${tempDir.path}/a.jpg')
        ..writeAsBytesSync(img.encodeJpg(img.Image(width: 4, height: 4)));
      final fakeUploader = _FakeS3Uploader(true);
      final coordinator = BackupCoordinator(
        targetsStore: targetsStore,
        recordStore: recordStore,
        s3Uploader: fakeUploader,
      );

      final succeeded = await coordinator.backUpDerivative(
        record: record,
        kind: DerivativeKind.original,
        filePath: photoFile.path,
      );

      expect(succeeded, 1);
      expect(fakeUploader.keys.single, 'originals/manual_abc.webp');
      // The original file itself is untouched — only a temp copy is re-encoded.
      expect(photoFile.existsSync(), isTrue);
    });

    test(
      'videos always upload as original, even with optimized selected',
      () async {
        final targetsStore = BackupTargetsStore(store: FakeSecureStore());
        await targetsStore.add(
          accessKeyId: 'a',
          secretAccessKey: 'b',
          region: 'us-east-1',
          bucket: 'bucket',
          prefix: '',
        );
        await targetsStore.setBackupFormat(BackupFormat.optimized);
        final recordStore = newRecordStore();
        final record = await recordStore.upsert(
          localId: 'manual:vid',
          contentHash: 'vid',
          platform: 'ios',
          isVideo: true,
        );
        final fakeUploader = _FakeS3Uploader(true);
        final coordinator = BackupCoordinator(
          targetsStore: targetsStore,
          recordStore: recordStore,
          s3Uploader: fakeUploader,
        );

        final succeeded = await coordinator.backUpDerivative(
          record: record,
          kind: DerivativeKind.original,
          filePath: '${tempDir.path}/a.mp4',
        );

        expect(succeeded, 1);
        expect(fakeUploader.keys.single, 'originals/manual_vid.mp4');
      },
    );

    test(
      'falls back to the original bytes when the file is not a decodable image',
      () async {
        final targetsStore = BackupTargetsStore(store: FakeSecureStore());
        await targetsStore.add(
          accessKeyId: 'a',
          secretAccessKey: 'b',
          region: 'us-east-1',
          bucket: 'bucket',
          prefix: '',
        );
        await targetsStore.setBackupFormat(BackupFormat.optimized);
        final recordStore = newRecordStore();
        final record = await recordStore.upsert(
          localId: 'manual:bad',
          contentHash: 'bad',
          platform: 'ios',
        );
        final notAnImage = File('${tempDir.path}/a.jpg')
          ..writeAsStringSync('not actually an image');
        final fakeUploader = _FakeS3Uploader(true);
        final coordinator = BackupCoordinator(
          targetsStore: targetsStore,
          recordStore: recordStore,
          s3Uploader: fakeUploader,
        );

        final succeeded = await coordinator.backUpDerivative(
          record: record,
          kind: DerivativeKind.original,
          filePath: notAnImage.path,
        );

        expect(succeeded, 1);
        expect(fakeUploader.keys.single, 'originals/manual_bad.jpg');
      },
    );
  });
}

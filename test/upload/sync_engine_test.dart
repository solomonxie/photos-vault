import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photos_vault/photos/on_device_vision.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/backup_coordinator.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/upload/s3_uploader.dart';
import 'package:photos_vault/upload/sync_engine.dart';
import 'package:photos_vault/upload/sync_job.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_sync_job_store.dart';

class _Uploader implements S3Uploader {
  @override
  Future<bool> put({
    required String filePath,
    required String key,
    required S3BackupTarget target,
  }) async => true;
}

void main() {
  late Directory dir;
  late FakeAssetRecordStore records;
  late FakeSyncJobStore jobs;
  late BackupTargetsStore targets;
  late Map<String, int> dates;
  late List<String> hashed;
  late String hash;
  var all = <AssetRecord>[];

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('pv_engine_');
    records = FakeAssetRecordStore();
    jobs = FakeSyncJobStore();
    targets = BackupTargetsStore(store: FakeSecureStore());
    await targets.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'bucket',
      prefix: '',
    );
    dates = {};
    hashed = [];
    hash = 'h1';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  SyncEngine engine({Set<SyncJobKind>? kinds}) {
    Future<String> hashFile(String path) async {
      hashed.add(path);
      return hash;
    }

    return SyncEngine(
      recordStore: records,
      targetsStore: targets,
      coordinator: BackupCoordinator(
        targetsStore: targets,
        recordStore: records,
        s3Uploader: _Uploader(),
        hashFile: hashFile,
      ),
      thumbnailCache: ThumbnailCache(
        store: records,
        directory: () async => dir,
        encode: (_) async => null,
        libraryThumbnail: (_) async => null,
      ),
      library: PhotoLibraryService(
        store: records,
        loadEntity: (id) async => AssetEntity(
          id: id,
          typeInt: 1,
          width: 10,
          height: 10,
          modifiedDateSecond: dates[id],
        ),
      ),
      syncJobStore: jobs,
      pendingDeletes: PendingDeletes(store: records),
      records: () => all,
      displayName: (r) => r.localId,
      hashFile: hashFile,
      kinds: kinds,
    );
  }

  Future<AssetRecord> backedUp(
    String localId, {
    String? libraryId,
    String? sourcePath,
  }) async {
    await records.upsert(
      localId: localId,
      contentHash: localId,
      platform: 'ios',
      sourceType: sourcePath == null
          ? AssetSourceType.photoManager
          : AssetSourceType.manualFile,
      sourcePath: sourcePath,
      libraryId: libraryId,
    );
    await records.updateDerivative(
      localId,
      DerivativeKind.original,
      DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'originals/$localId.jpg',
        backedUpHash: hash,
      ),
    );
    return (await records.getByLocalId(localId))!;
  }

  SyncJob job(String localId, SyncJobKind kind) => SyncJob(
    id: 'j',
    localId: localId,
    kind: kind,
    displayName: localId,
    status: SyncJobStatus.running,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    assetCreatedAt: DateTime(2026),
  );

  Future<Set<String>> queuedChecks() async => {
    for (final j in await jobs.all())
      if (j.kind == SyncJobKind.checkChanges) j.localId,
  };

  group('change checks follow the modification date (BG-6)', () {
    test(
      'only photos never checked, or whose date moved, are queued',
      () async {
        await backedUp('photo:never', libraryId: 'N');
        await backedUp('photo:same', libraryId: 'S');
        await backedUp('photo:moved', libraryId: 'M');
        await records.markChecked('photo:same', 100);
        await records.markChecked('photo:moved', 100);
        // What a scan of Photos after an edit there stamps.
        await records.noteModified({'photo:same': 100, 'photo:moved': 200});

        // A lane that never drains checks, so the queue can be read back.
        all = await records.listAll();
        await engine(kinds: {SyncJobKind.uploadOriginal}).enqueueChangeChecks();

        expect(await queuedChecks(), {'photo:never', 'photo:moved'});
      },
    );

    test('a date still the one it was checked at reads no file', () async {
      await backedUp('photo:a', libraryId: 'A');
      await records.markChecked('photo:a', 100);
      dates['A'] = 100;

      await engine().processJob(job('photo:a', SyncJobKind.checkChanges));

      expect(hashed, isEmpty);
      expect(await records.changeChecksDue(), isEmpty);
    });

    test('an unchanged file is hashed once, then left alone', () async {
      final file = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
      await backedUp('manual:a', sourcePath: file.path);
      final e = engine();

      await e.processJob(job('manual:a', SyncJobKind.checkChanges));
      expect(hashed, [file.path]);
      expect(await records.checkedModified('manual:a'), isNotNull);

      await e.processJob(job('manual:a', SyncJobKind.checkChanges));
      expect(hashed, [file.path], reason: 'same date, no second hash');
      expect(
        (await records.getByLocalId('manual:a'))!
            .stateOf(DerivativeKind.original)
            .status,
        UploadStatus.uploaded,
      );
    });

    test('a file rewritten since its check is queued, hashed and sent '
        'again', () async {
      final file = File('${dir.path}/b.jpg')..writeAsBytesSync([1, 2, 3]);
      await backedUp('manual:b', sourcePath: file.path);
      final then = file.lastModifiedSync();
      await records.markChecked(
        'manual:b',
        then.millisecondsSinceEpoch ~/ 1000,
      );
      final narrow = engine(kinds: {SyncJobKind.uploadOriginal});
      all = await records.listAll();
      await narrow.enqueueChangeChecks();
      expect(await queuedChecks(), isEmpty);

      file
        ..writeAsBytesSync([4, 5, 6])
        ..setLastModifiedSync(then.add(const Duration(minutes: 5)));
      await narrow.enqueueChangeChecks();
      expect(await queuedChecks(), {'manual:b'});

      hash = 'h2';
      await engine(kinds: {SyncJobKind.checkChanges})
          .processJob(job('manual:b', SyncJobKind.checkChanges));
      expect(hashed, [file.path]);
      expect(
        (await records.getByLocalId('manual:b'))!
            .stateOf(DerivativeKind.original)
            .status,
        UploadStatus.pending,
      );
    });

    test('an upload records the date it was read at', () async {
      final file = File('${dir.path}/c.jpg')..writeAsBytesSync([7]);
      await records.upsert(
        localId: 'manual:c',
        contentHash: 'c',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: file.path,
      );

      await engine().processJob(job('manual:c', SyncJobKind.uploadOriginal));

      final after = (await records.getByLocalId('manual:c'))!
          .stateOf(DerivativeKind.original);
      expect(after.status, UploadStatus.uploaded);
      expect(after.backedUpHash, 'h1');
      expect(hashed, [file.path], reason: 'one hash per upload (BG-5)');
      expect(
        await records.checkedModified('manual:c'),
        file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000,
      );
    });
  });

  test('Vision reads a camera-roll photo as its asset, a held one as its '
      'file', () async {
    final e = engine();
    final roll = await records.upsert(
      localId: 'photo:r',
      contentHash: 'r',
      platform: 'ios',
      libraryId: 'R',
    );
    final file = File('${dir.path}/h.jpg')..writeAsBytesSync(Uint8List(3));
    final held = await records.upsert(
      localId: 'manual:h',
      contentHash: 'h',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: file.path,
    );

    expect(
      await e.visionSourceFor(roll),
      OnDeviceVisionService.assetSource('R'),
    );
    expect(await e.visionSourceFor(held), file.path);
  });
}

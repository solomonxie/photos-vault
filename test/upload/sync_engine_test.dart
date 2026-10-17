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
import '../support/scripted_deletes.dart';

class _Uploader implements S3Uploader {
  _Uploader(this.puts);

  final List<String> puts;

  @override
  Future<bool> put({
    required String filePath,
    required String key,
    required S3BackupTarget target,
  }) async {
    puts.add(key);
    return true;
  }
}

void main() {
  late Directory dir;
  late FakeAssetRecordStore records;
  late FakeSyncJobStore jobs;
  late BackupTargetsStore targets;
  late Map<String, int> dates;
  late List<String> hashed;
  late String hash;
  late Map<String, String> hashes;
  late List<String> puts;
  late Map<(String, bool), StillResource> resources;
  late List<String> resourceReads;
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
    hashes = {};
    puts = [];
    resources = {};
    resourceReads = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  SyncEngine engine({Set<SyncJobKind>? kinds}) {
    Future<String> hashFile(String path) async {
      hashed.add(path);
      return hashes[path] ?? hash;
    }

    return SyncEngine(
      recordStore: records,
      targetsStore: targets,
      coordinator: BackupCoordinator(
        targetsStore: targets,
        recordStore: records,
        s3Uploader: _Uploader(puts),
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
        loadResource: (entity, {required base}) async {
          resourceReads.add('${entity.id}/${base ? 'base' : 'current'}');
          return resources[(entity.id, base)];
        },
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

  group('originals as PhotoKit stores them, edits beside them (PW3b)', () {
    Future<String> targetId() async => (await targets.loadAll()).single.id;

    /// A backup made before PW3b: a JPEG render's hash, sent to the bucket
    /// [at] (ms).
    Future<void> legacy(String localId, String libraryId, int at) async {
      await backedUp(localId, libraryId: libraryId);
      final tid = await targetId();
      await records.recordUpload(
        localId: localId,
        kind: DerivativeKind.original,
        targetId: tid,
        destinationKey: 'originals/$localId.jpg',
        sourceHash: hash,
      );
      records.uploadedAt['$localId/original/$tid'] = at;
    }

    /// `tmp/.image` files photo_manager would write for asset [id].
    void edits(String id, {bool edited = true}) {
      final cache = Directory('${dir.path}/.image')..createSync();
      final base = File('${cache.path}/${id}_1_o_IMG_1.HEIC')
        ..writeAsBytesSync([1]);
      final render = File('${cache.path}/${id}_1_o_FullSizeRender.heic')
        ..writeAsBytesSync([2]);
      hashes[base.path] = 'base-$id';
      hashes[render.path] = 'render-$id';
      resources[(id, true)] = StillResource(base.path, edited: edited);
      resources[(id, false)] = StillResource(
        edited ? render.path : base.path,
        edited: edited,
      );
    }

    Future<Set<String>> queued(SyncJobKind kind) async => {
      for (final j in await jobs.all())
        if (j.kind == kind) j.localId,
    };

    test('the switch re-sends nothing and queues no delete for a library '
        'already backed up', () async {
      final now = DateTime.now();
      final monthAgo =
          now.subtract(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000;
      final uploaded = now
          .subtract(const Duration(days: 3))
          .millisecondsSinceEpoch;
      for (var i = 0; i < 6; i++) {
        await legacy('photo:$i', 'L$i', uploaded);
        dates['L$i'] = monthAgo;
      }
      // A scan has dated half of them; the rest are read live by their
      // check.
      await records.noteModified({
        for (var i = 0; i < 3; i++) 'photo:$i': monthAgo,
      });
      all = await records.listAll();

      // A lane that never drains checks: the queue is read back, then
      // every job run by hand.
      await engine(kinds: {SyncJobKind.analyzePhoto}).enqueueChangeChecks();
      expect(await queuedChecks(), {'photo:3', 'photo:4', 'photo:5'});
      final e = engine(kinds: {SyncJobKind.analyzePhoto});
      for (final j in await jobs.all()) {
        await e.processJob(j);
      }

      expect(puts, isEmpty, reason: 'nothing re-sent');
      expect(await PendingDeletes(store: records).pending(), isEmpty);
      expect(hashed, isEmpty, reason: 'no render, no hash');
      expect(resourceReads, isEmpty);
      expect(await records.changeChecksDue(), isEmpty);
      expect(await queued(SyncJobKind.uploadOriginal), isEmpty);
      for (final r in await records.listAll()) {
        expect(r.isFullyBackedUp, isTrue);
        expect(r.hasEdit, isFalse);
        expect(
          r.stateOf(DerivativeKind.original).destinationKey,
          'originals/${r.localId}.jpg',
        );
      }
    });

    test('a date within a day of the upload, or a row adopted from before '
        'per-bucket state, is never taken for current', () async {
      final now = DateTime.now();
      await legacy('photo:near', 'N', now.millisecondsSinceEpoch);
      await legacy('photo:adopted', 'A', now.millisecondsSinceEpoch);
      records.uploads['photo:adopted/original'] = {
        '': (key: 'originals/photo:adopted.jpg', hash: hash),
      };
      records.uploadedAt['photo:adopted/original/'] =
          now.millisecondsSinceEpoch;
      final old =
          now.subtract(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000;
      await records.noteModified({
        'photo:near': now.millisecondsSinceEpoch ~/ 1000 - 3600,
        'photo:adopted': old,
      });

      expect(await records.rebaselineChangeChecks(), 0);
      expect(await records.changeChecksDue(), {'photo:near', 'photo:adopted'});
    });

    test(
      'an edited photo uploads two objects: its original and the edit',
      () async {
        await records.upsert(
          localId: 'photo:e',
          contentHash: 'e',
          platform: 'ios',
          libraryId: 'E',
        );
        edits('E');
        dates['E'] = 100;
        final e = engine(kinds: {SyncJobKind.analyzePhoto});

        await e.processJob(job('photo:e', SyncJobKind.uploadOriginal));
        var r = (await records.getByLocalId('photo:e'))!;
        expect(r.hasEdit, isTrue);
        expect(
          r.isFullyBackedUp,
          isFalse,
          reason: 'the edit is still only on this phone',
        );
        expect(await queued(SyncJobKind.uploadEdited), {'photo:e'});

        await e.processJob(job('photo:e', SyncJobKind.uploadEdited));
        r = (await records.getByLocalId('photo:e'))!;
        expect(puts, hasLength(2));
        final stem = puts.first.substring(
          'originals/'.length,
          puts.first.lastIndexOf('.'),
        );
        expect(puts, ['originals/$stem.HEIC', 'edited/$stem.heic']);
        final original = r.stateOf(DerivativeKind.original);
        expect(original.backedUpHash, 'base-E');
        expect(original.fromResource, isTrue);
        expect(r.stateOf(DerivativeKind.edited).backedUpHash, 'render-E');
        expect(r.isFullyBackedUp, isTrue);
        expect(await PendingDeletes(store: records).pending(), isEmpty);
        expect(
          Directory('${dir.path}/.image').listSync(),
          isEmpty,
          reason: "photo_manager's copies go once the puts are over",
        );
        expect(await records.checkedModified('photo:e'), 100);
      },
    );

    test(
      'an unedited photo goes up as its original alone, and owes no edit',
      () async {
        await records.upsert(
          localId: 'photo:u',
          contentHash: 'u',
          platform: 'ios',
          libraryId: 'U',
        );
        edits('U', edited: false);
        await engine(kinds: {SyncJobKind.analyzePhoto})
            .processJob(job('photo:u', SyncJobKind.uploadOriginal));

        final r = (await records.getByLocalId('photo:u'))!;
        expect(puts.single, endsWith('.HEIC'));
        expect(r.hasEdit, isFalse);
        expect(r.isFullyBackedUp, isTrue);
        expect(await queued(SyncJobKind.uploadEdited), isEmpty);
      },
    );

    test('a later edit sends the edit again over its own key, never the '
        'original, and deletes nothing', () async {
      await records.upsert(
        localId: 'photo:e',
        contentHash: 'e',
        platform: 'ios',
        libraryId: 'E',
      );
      edits('E');
      dates['E'] = 100;
      final e = engine(kinds: {SyncJobKind.analyzePhoto});
      await e.processJob(job('photo:e', SyncJobKind.uploadOriginal));
      await e.processJob(job('photo:e', SyncJobKind.uploadEdited));
      final sent = [...puts];
      puts.clear();

      // Favourited in Photos: the date moves, the bytes don't.
      edits('E');
      dates['E'] = 200;
      await e.processJob(job('photo:e', SyncJobKind.checkChanges));
      expect(puts, isEmpty);
      expect(await records.checkedModified('photo:e'), 200);

      // Edited again.
      edits('E');
      hashes[resources[('E', false)]!.path] = 'render-E-2';
      dates['E'] = 300;
      await e.processJob(job('photo:e', SyncJobKind.checkChanges));
      final flipped = (await records.getByLocalId('photo:e'))!;
      expect(
        flipped.stateOf(DerivativeKind.edited).status,
        UploadStatus.pending,
      );
      await e.processJob(job('photo:e', SyncJobKind.uploadOriginal));
      await e.processJob(job('photo:e', SyncJobKind.uploadEdited));

      expect(puts, [sent.last], reason: 'the original is already there');
      final r = (await records.getByLocalId('photo:e'))!;
      expect(r.stateOf(DerivativeKind.edited).backedUpHash, 'render-E-2');
      expect(r.isFullyBackedUp, isTrue);
      expect(await PendingDeletes(store: records).pending(), isEmpty);
    });

    test(
      'an old backup edited since: its render goes only once the new '
      'original and edit are both up, the original kept in its place',
      () async {
        await legacy('photo:old', 'O', DateTime(2025).millisecondsSinceEpoch);
        // What a change check that found the edit leaves.
        final before = (await records.getByLocalId('photo:old'))!;
        await records.updateDerivative(
          'photo:old',
          DerivativeKind.original,
          before
              .stateOf(DerivativeKind.original)
              .copyWith(status: UploadStatus.pending),
        );
        edits('O');
        final e = engine(kinds: {SyncJobKind.analyzePhoto});
        final deleted = <String>[];
        final drain = PendingDeletes(
          store: records,
          ops: ScriptedDeletes((_, key) async {
            deleted.add(key);
            return true;
          }),
        );

        await e.processJob(job('photo:old', SyncJobKind.uploadOriginal));
        expect(puts, ['originals/photo:old.HEIC']);
        final task = (await drain.pending()).single;
        expect(task.objectKey, 'originals/photo:old.jpg');
        expect(task.keep, 'originals/photo:old.HEIC');
        expect(task.untilWhole, isTrue);
        await drain.drain(await targets.loadAll());
        expect(deleted, isEmpty, reason: 'the edit is not up yet');

        await e.processJob(job('photo:old', SyncJobKind.uploadEdited));
        expect(puts.last, 'edited/photo:old.heic');
        await drain.drain(await targets.loadAll());
        expect(deleted, ['originals/photo:old.jpg']);
      },
    );

    test('a photo back from the bucket as its edit is checked against the '
        'edit, and a change to it is sent as the edit', () async {
      final file = File('${dir.path}/back.heic')..writeAsBytesSync([3]);
      await backedUp('photo:b', sourcePath: file.path);
      await records.setHasEdit('photo:b', true);
      await records.updateDerivative(
        'photo:b',
        DerivativeKind.edited,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'edited/photo:b.heic',
          backedUpHash: 'edit-hash',
        ),
      );
      hashes[file.path] = 'edit-hash';
      final e = engine(kinds: {SyncJobKind.analyzePhoto});

      await e.processJob(job('photo:b', SyncJobKind.checkChanges));
      expect((await records.getByLocalId('photo:b'))!.isFullyBackedUp, isTrue);

      hashes[file.path] = 'changed';
      await records.markChecked('photo:b', 1);
      await e.processJob(job('photo:b', SyncJobKind.checkChanges));
      final r = (await records.getByLocalId('photo:b'))!;
      expect(r.stateOf(DerivativeKind.original).status, UploadStatus.uploaded);
      expect(r.stateOf(DerivativeKind.edited).status, UploadStatus.pending);

      await e.processJob(job('photo:b', SyncJobKind.uploadOriginal));
      expect(puts, isEmpty, reason: 'an original only ever from PhotoKit');
      await e.processJob(job('photo:b', SyncJobKind.uploadEdited));
      expect(puts, ['edited/photo:b.heic']);
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

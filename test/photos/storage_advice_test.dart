import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/storage_advice.dart';
import 'package:photos_vault/storage/asset_record.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  AssetRecord record({
    String localId = 'photo:1',
    bool isVideo = false,
    bool isHidden = false,
    bool localDeleted = false,
    DateTime? deletedAt,
    UploadStatus original = UploadStatus.uploaded,
    int? width,
    int? height,
    String? passcodeHash,
    String? libraryId,
  }) => AssetRecord(
    localId: localId,
    contentHash: localId,
    platform: 'ios',
    createdAt: DateTime(2026, 2, 14),
    updatedAt: DateTime(2026, 2, 14),
    isVideo: isVideo,
    isHidden: isHidden,
    localDeleted: localDeleted,
    deletedAt: deletedAt,
    passcodeHash: passcodeHash,
    libraryId: libraryId,
    width: width,
    height: height,
    derivatives: {DerivativeKind.original: DerivativeState(status: original)},
  );

  StorageItem? advise(
    AssetRecord r, {
    int bytes = 1024,
    String name = 'IMG_1.heic',
    bool appOwned = false,
  }) => adviseOn(record: r, bytes: bytes, name: name, appOwned: appOwned);

  group('adviseOn', () {
    test('every fix waits behind a backup, because every fix needs one', () {
      final item = advise(
        record(original: UploadStatus.pending),
        bytes: 60 * 1024 * 1024,
      )!;

      expect(item.issues, contains(StorageIssue.largeFile));
      expect(item.issues, isNot(contains(StorageIssue.onDevice)));
      expect(item.fix, StorageFix.backUpFirst);
      expect(item.estimatedSaving, 0);
    });

    test('an un-backed-up photo with nothing wrong with it is not listed', () {
      // Not backed up is the sync queue's problem, not this page's.
      expect(
        advise(record(original: UploadStatus.pending), bytes: 900),
        isNull,
      );
    });

    test('a backed-up photo still on the device is offered a removal', () {
      final item = advise(record(), bytes: 5 * 1024 * 1024)!;

      expect(item.issues, {StorageIssue.onDevice});
      expect(item.fix, StorageFix.removeFromDevice);
      expect(item.estimatedSaving, 5 * 1024 * 1024);
    });

    test('a backed-up video is removable now it has a poster frame', () {
      final item = advise(
        record(isVideo: true, libraryId: 'lib-1'),
        bytes: 900 * 1024 * 1024,
      )!;

      expect(item.issues, contains(StorageIssue.onDevice));
      expect(item.issues, contains(StorageIssue.largeFile));
      expect(item.fix, StorageFix.removeFromDevice);
      expect(item.estimatedSaving, 900 * 1024 * 1024);
    });

    test('an imported video with no frame to draw is left out of it', () {
      // Nothing in the photo library to take a poster frame from, and no
      // frame extractor of our own — removing it would blank the tile.
      expect(advise(record(isVideo: true), bytes: 900 * 1024 * 1024), isNull);
    });

    test('an un-backed-up video is still offered a backup', () {
      final item = advise(
        record(isVideo: true, original: UploadStatus.failed),
        bytes: 900 * 1024 * 1024,
      )!;

      expect(item.fix, StorageFix.backUpFirst);
    });

    test('an app-owned oversized photo is shrunk rather than removed', () {
      final item = advise(
        record(width: 6000, height: 4000),
        bytes: 40 * 1024 * 1024,
        name: 'scan.png',
        appOwned: true,
      )!;

      expect(item.issues, {
        StorageIssue.onDevice,
        StorageIssue.largeFile,
        StorageIssue.highResolution,
        StorageIssue.optimizableFormat,
      });
      expect(item.fix, StorageFix.reduceResolution);
      // 6000 px down to 2560 keeps (2560/6000)² of the pixels.
      expect(item.estimatedSaving, greaterThan(30 * 1024 * 1024));
      expect(item.estimatedSaving, lessThan(40 * 1024 * 1024));
    });

    test('an app-owned optimizable format at a sane size is converted', () {
      final item = advise(
        record(width: 1200, height: 900),
        bytes: 8 * 1024 * 1024,
        name: 'chart.png',
        appOwned: true,
      )!;

      expect(item.issues, contains(StorageIssue.optimizableFormat));
      expect(item.fix, StorageFix.convertFormat);
    });

    test('a camera-roll photo says why it is big but is only removable', () {
      // PhotoKit owns the file, so the tags explain the size and the
      // honest fix is still a removal.
      final item = advise(
        record(width: 8064, height: 6048),
        bytes: 60 * 1024 * 1024,
        name: 'IMG_4934.png',
      )!;

      expect(item.issues, contains(StorageIssue.highResolution));
      expect(item.issues, contains(StorageIssue.optimizableFormat));
      expect(item.fix, StorageFix.removeFromDevice);
    });

    test('a not-yet-backed-up file is never rewritten either', () {
      final item = advise(
        record(original: UploadStatus.pending, width: 6000, height: 4000),
        bytes: 40 * 1024 * 1024,
        name: 'scan.png',
        appOwned: true,
      )!;

      expect(item.issues, contains(StorageIssue.highResolution));
      expect(item.fix, StorageFix.backUpFirst);
    });

    test('large is 10 MB for a photo and 100 MB for a video', () {
      bool large(StorageItem? item) =>
          item?.issues.contains(StorageIssue.largeFile) ?? false;

      expect(large(advise(record(), bytes: largePhotoBytes)), isTrue);
      expect(large(advise(record(), bytes: largePhotoBytes - 1)), isFalse);
      final video = record(isVideo: true, original: UploadStatus.pending);
      expect(large(advise(video, bytes: largeVideoBytes)), isTrue);
      expect(large(advise(video, bytes: largeVideoBytes - 1)), isFalse);
      // A 50 MB video is unremarkable; a 50 MB photo is not.
      expect(large(advise(record(), bytes: 50 * 1024 * 1024)), isTrue);
    });

    test(
      'small backed-up files below every threshold still list a removal',
      () {
        final item = advise(record(), bytes: 900)!;

        expect(item.issues, isNot(contains(StorageIssue.largeFile)));
        expect(item.fix, StorageFix.removeFromDevice);
      },
    );

    test('cloud-only, binned and hidden assets are never listed', () {
      expect(advise(record(localDeleted: true)), isNull);
      expect(advise(record(deletedAt: DateTime(2026))), isNull);
      expect(advise(record(isHidden: true)), isNull);
      expect(advise(record(passcodeHash: 'abc')), isNull);
    });
  });

  group('StorageAdvisor.scan', () {
    test('measures every candidate and lists the biggest file first', () async {
      final store = FakeAssetRecordStore();
      for (var i = 0; i < 3; i++) {
        await store.upsert(
          localId: 'photo:$i',
          contentHash: '$i',
          platform: 'ios',
          createdAt: DateTime(2026, 1, i + 1),
        );
        await store.updateDerivative(
          'photo:$i',
          DerivativeKind.original,
          const DerivativeState(status: UploadStatus.uploaded),
        );
      }
      final sizes = {'photo:0': 1000, 'photo:1': 9000, 'photo:2': 3000};

      final found = await StorageAdvisor(
        store: store,
        measure: (r) async => AssetMeasure(
          bytes: sizes[r.localId]!,
          name: '${r.localId}.heic',
          appOwned: false,
        ),
      ).scan();

      expect(found.items.map((i) => i.bytes), [9000, 3000, 1000]);
    });

    test('skips assets nothing can be measured about', () async {
      final store = FakeAssetRecordStore();
      await store.upsert(
        localId: 'photo:gone',
        contentHash: 'gone',
        platform: 'ios',
      );

      final found = await StorageAdvisor(
        store: store,
        measure: (_) async => null,
      ).scan();

      expect(found.items, isEmpty);
    });

    test('never measures an asset it would refuse to list', () async {
      final store = FakeAssetRecordStore();
      await store.upsert(
        localId: 'photo:hidden',
        contentHash: 'h',
        platform: 'ios',
      );
      await store.setHidden('photo:hidden', true);
      final measured = <String>[];

      await StorageAdvisor(
        store: store,
        measure: (r) async {
          measured.add(r.localId);
          return null;
        },
      ).scan();

      expect(measured, isEmpty);
    });

    test('files what it found, and reads it back without measuring', () async {
      final store = FakeAssetRecordStore();
      await store.upsert(
        localId: 'photo:0',
        contentHash: '0',
        platform: 'ios',
        createdAt: DateTime(2026),
      );
      await store.updateDerivative(
        'photo:0',
        DerivativeKind.original,
        const DerivativeState(status: UploadStatus.uploaded),
      );
      var measures = 0;
      StorageAdvisor advisor() => StorageAdvisor(
        store: store,
        now: () => DateTime(2026, 9, 19, 12, 16),
        measure: (_) async {
          measures++;
          return const AssetMeasure(
            bytes: 30 * 1024 * 1024,
            name: 'a.heic',
            appOwned: false,
          );
        },
      );

      await advisor().scan();
      final reopened = await advisor().cached();

      expect(measures, 1);
      expect(reopened.scannedAt, DateTime(2026, 9, 19, 12, 16));
      expect(reopened.items.single.bytes, 30 * 1024 * 1024);
    });

    test(
      'a cached item is re-judged against the record as it is now',
      () async {
        final store = FakeAssetRecordStore();
        await store.upsert(
          localId: 'photo:0',
          contentHash: '0',
          platform: 'ios',
        );
        await store.updateDerivative(
          'photo:0',
          DerivativeKind.original,
          const DerivativeState(status: UploadStatus.uploaded),
        );
        final advisor = StorageAdvisor(
          store: store,
          measure: (_) async => const AssetMeasure(
            bytes: 30 * 1024 * 1024,
            name: 'a.heic',
            appOwned: false,
          ),
        );
        await advisor.scan();

        // Removed from the device since — the cache must not go on offering
        // to remove it again.
        await store.setLocalDeleted('photo:0', true);

        expect((await advisor.cached()).items, isEmpty);
      },
    );

    test('a cached item hidden since is dropped from the read-back', () async {
      final store = FakeAssetRecordStore();
      await store.upsert(localId: 'photo:0', contentHash: '0', platform: 'ios');
      await store.updateDerivative(
        'photo:0',
        DerivativeKind.original,
        const DerivativeState(status: UploadStatus.uploaded),
      );
      final advisor = StorageAdvisor(
        store: store,
        measure: (_) async => const AssetMeasure(
          bytes: 30 * 1024 * 1024,
          name: 'a.heic',
          appOwned: false,
        ),
      );
      await advisor.scan();
      expect((await advisor.cached()).items, hasLength(1));

      await store.setHidden('photo:0', true);

      expect((await advisor.cached()).items, isEmpty);
    });

    test('a pass stopped halfway resumes instead of starting over', () async {
      final store = FakeAssetRecordStore();
      for (var i = 0; i < 6; i++) {
        await store.upsert(
          localId: 'photo:$i',
          contentHash: '$i',
          platform: 'ios',
          createdAt: DateTime(2026, 1, i + 1),
        );
        await store.updateDerivative(
          'photo:$i',
          DerivativeKind.original,
          const DerivativeState(status: UploadStatus.uploaded),
        );
      }
      final measured = <String>[];
      StorageAdvisor advisor() => StorageAdvisor(
        store: store,
        measure: (r) async {
          measured.add(r.localId);
          return AssetMeasure(
            bytes: 1024,
            name: '${r.localId}.heic',
            appOwned: false,
          );
        },
      );

      // Leaving the page halfway used to throw the whole pass away.
      final half = await advisor().scan(limit: 2);
      expect(half.complete, isFalse);
      expect(half.measured, hasLength(2));
      measured.clear();

      final rest = await advisor().scan();

      expect(measured, isNot(contains('photo:0')));
      expect(measured, hasLength(4));
      expect(rest.complete, isTrue);
      expect(rest.items, hasLength(6));
      expect(rest.scannedAt, isNotNull);
    });

    test('a finished pass measures nothing until asked to restart', () async {
      final store = FakeAssetRecordStore();
      await store.upsert(localId: 'photo:0', contentHash: '0', platform: 'ios');
      await store.updateDerivative(
        'photo:0',
        DerivativeKind.original,
        const DerivativeState(status: UploadStatus.uploaded),
      );
      var measures = 0;
      StorageAdvisor advisor() => StorageAdvisor(
        store: store,
        measure: (_) async {
          measures++;
          return const AssetMeasure(
            bytes: 1024,
            name: 'a.heic',
            appOwned: false,
          );
        },
      );

      await advisor().scan();
      await advisor().scan();
      expect(measures, 1);

      await advisor().scan(restart: true);
      expect(measures, 2);
    });

    test('a photo added since is picked up without a restart', () async {
      final store = FakeAssetRecordStore();
      Future<void> add(String id) async {
        await store.upsert(localId: id, contentHash: id, platform: 'ios');
        await store.updateDerivative(
          id,
          DerivativeKind.original,
          const DerivativeState(status: UploadStatus.uploaded),
        );
      }

      await add('photo:0');
      final advisor = StorageAdvisor(
        store: store,
        measure: (r) async => AssetMeasure(
          bytes: 1024,
          name: '${r.localId}.heic',
          appOwned: false,
        ),
      );
      expect((await advisor.scan()).complete, isTrue);

      await add('photo:1');

      expect((await advisor.scan()).items, hasLength(2));
    });

    test('nothing scanned yet reads back as never scanned', () async {
      final scan = await StorageAdvisor(store: FakeAssetRecordStore()).cached();

      expect(scan.neverScanned, isTrue);
      expect(scan.items, isEmpty);
    });

    test('remeasure only re-reads the assets a fix touched', () async {
      final store = FakeAssetRecordStore();
      for (final id in ['a', 'b']) {
        await store.upsert(localId: id, contentHash: id, platform: 'ios');
        await store.updateDerivative(
          id,
          DerivativeKind.original,
          const DerivativeState(status: UploadStatus.uploaded),
        );
      }
      final measured = <String>[];
      final advisor = StorageAdvisor(
        store: store,
        measure: (r) async {
          measured.add(r.localId);
          return AssetMeasure(
            bytes: r.localId == 'a' ? 30 * 1024 * 1024 : 20 * 1024 * 1024,
            name: '${r.localId}.heic',
            appOwned: false,
          );
        },
      );
      final scanned = await advisor.scan();
      measured.clear();

      final after = await advisor.remeasure(scanned, {'a'});

      expect(measured, ['a']);
      expect(after.items.map((i) => i.record.localId), ['a', 'b']);
      expect(after.scannedAt, scanned.scannedAt);
    });

    test('reports progress against the number of candidates', () async {
      final store = FakeAssetRecordStore();
      await store.upsert(localId: 'photo:0', contentHash: '0', platform: 'ios');
      final reports = <(int, int)>[];

      await StorageAdvisor(
        store: store,
        measure: (_) async =>
            const AssetMeasure(bytes: 10, name: 'a.heic', appOwned: false),
      ).scan(onProgress: (_, done, total) => reports.add((done, total)));

      expect(reports, [(1, 1)]);
    });
  });

  test('formatBytes steps up a unit at a time', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(20 * 1024 * 1024), '20.0 MB');
    expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
  });
}

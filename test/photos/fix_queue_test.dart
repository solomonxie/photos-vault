import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/fix_queue.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/photos/storage_advice.dart';
import 'package:photos_vault/photos/storage_optimizer.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:photos_vault/upload/bucket_flagged.dart';
import 'package:photos_vault/upload/bucket_leftovers.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';

void main() {
  late Directory tempDir;
  late FakeAssetRecordStore store;
  var refreshes = 0;
  Completer<void>? gate;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pv_fix_queue_');
    store = FakeAssetRecordStore();
    refreshes = 0;
    gate = null;
  });
  tearDown(() => tempDir.delete(recursive: true));

  FixQueue queue() {
    final advisor = StorageAdvisor(
      store: store,
      measure: (record) async => AssetMeasure(
        bytes: 1000,
        name: '${record.localId}.png',
        appOwned: true,
      ),
    );
    return FixQueue(
      store: store,
      advisor: advisor,
      optimizer: StorageOptimizer(
        store: store,
        thumbnails: ThumbnailCache(
          store: store,
          directory: () async => tempDir,
          encode: (_) async => Uint8List.fromList([9]),
        ),
        library: PhotoLibraryService(store: FakeAssetRecordStore()),
        backUp: (_) async => gate?.future,
      ),
      fixer: BucketFixer(
        store: store,
        targetsStore: BackupTargetsStore(store: FakeSecureStore()),
        passphrases: () async => const [],
      ),
      refreshBucket: () async => refreshes++,
    );
  }

  /// A backed-up photo this app owns. A [gone] one has neither its file
  /// nor a thumbnail, so a removal is refused.
  Future<Flag> owned(
    String id, {
    bool gone = false,
    StorageFix fix = StorageFix.removeFromDevice,
  }) async {
    final file = File('${tempDir.path}/$id.png');
    if (!gone) file.writeAsBytesSync(Uint8List(1000));
    await store.upsert(
      localId: id,
      contentHash: id,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: file.path,
    );
    await store.updateDerivative(
      id,
      DerivativeKind.original,
      const DerivativeState(status: UploadStatus.uploaded),
    );
    await store.updateDerivative(
      id,
      DerivativeKind.thumbnail,
      const DerivativeState(status: UploadStatus.uploaded),
    );
    if (!gone) {
      await store.setThumbnailPath(
        id,
        (File('${tempDir.path}/$id.jpg')..writeAsBytesSync([1])).path,
      );
    }
    return Flag.storage(
      StorageItem(
        record: (await store.getByLocalId(id))!,
        bytes: 1000,
        name: '$id.png',
        appOwned: true,
        issues: const {StorageIssue.onDevice},
        fixes: [fix],
      ),
    );
  }

  Future<void> drained(FixQueue q) async {
    while (q.running) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('a batch drains: fixed items resolve, a refused one stays with its '
      'reason', () async {
    final q = queue();
    final a = await owned('a');
    final b = await owned('b', gone: true);

    q.enqueue([a, b], FlagSolution.removeFromDevice);
    expect(q.total, 2);
    await drained(q);

    expect(q.isResolved(a), isTrue);
    expect(q.isResolved(b), isFalse);
    expect(q.jobs[b.id]!.state, FixJobState.failed);
    expect(q.done, 2);
    expect(q.failed, 1);
    expect(q.freedBytes, 1000);
    expect(q.finished, isTrue);
    expect(File('${tempDir.path}/a.png').existsSync(), isFalse);
  });

  test('Optimize keeps videos apart from photos, and counts copies as they '
      'are made', () async {
    final batches = <List<String>>[];
    final seen = <int>[];
    late FixQueue q;
    final optimizer = _RecordingOptimizer(
      store: store,
      thumbnails: ThumbnailCache(store: store, directory: () async => tempDir),
      library: PhotoLibraryService(store: FakeAssetRecordStore()),
      backUp: (_) async {},
      onApply: (items, onPrepared) {
        batches.add([for (final i in items) i.record.localId]);
        for (final i in items) {
          onPrepared?.call(i.record.localId);
        }
        seen.add(q.progressed);
      },
    );
    q = FixQueue(
      store: store,
      advisor: StorageAdvisor(store: store),
      optimizer: optimizer,
      fixer: BucketFixer(
        store: store,
        targetsStore: BackupTargetsStore(store: FakeSecureStore()),
        passphrases: () async => const [],
      ),
      refreshBucket: () async {},
    );
    Future<Flag> item(String id, {bool video = false}) async {
      await store.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.photoManager,
        isVideo: video,
      );
      return Flag.storage(
        StorageItem(
          record: (await store.getByLocalId(id))!,
          bytes: 1000,
          name: id,
          appOwned: false,
          issues: const {StorageIssue.largeFile},
          fixes: const [StorageFix.optimize],
        ),
      );
    }

    q.enqueue([
      await item('v1', video: true),
      await item('p1'),
      await item('v2', video: true),
      await item('p2'),
    ], FlagSolution.optimize);
    await drained(q);

    expect(batches, [
      ['v1', 'v2'],
      ['p1', 'p2'],
    ]);
    expect(seen, [2, 4]);
  });

  test('a retry of a failed item counts it once', () async {
    final q = queue();
    final b = await owned('b', gone: true);
    q.enqueue([b], FlagSolution.removeFromDevice);
    await drained(q);
    expect(q.failed, 1);

    q.enqueue([b], FlagSolution.removeFromDevice);
    await drained(q);
    expect(q.failed, 1);
    expect(q.total, 1);
  });

  test('stop drops what had not started', () async {
    final q = queue();
    gate = Completer();
    final a = await owned('a', fix: StorageFix.backUpFirst);
    final b = await owned('b');
    q.enqueue([a], FlagSolution.backUp);
    q.enqueue([b], FlagSolution.removeFromDevice);
    await Future<void>.delayed(Duration.zero);

    q.stop();
    expect(q.jobs.containsKey(b.id), isFalse);
    expect(q.total, 1);
    gate!.complete();
    await drained(q);
    expect(q.isResolved(a), isTrue);
    expect(q.isResolved(b), isFalse);
  });

  test('waiting work is filed, and a new launch picks it up', () async {
    final object = BucketObject(
      targetId: 't',
      key: 'photos-vault/originals/holiday.jpg',
      size: 10,
      lastModified: DateTime(2026),
    );
    await store.replaceBucketObjects('t', [object]);
    final flag = Flag.bucket(
      FlaggedObject(
        object: object,
        kind: FlagKind.likelyLeftover,
        takenAt: DateTime(2020),
      ),
    );

    // Held on the backup in front of it, then the app is killed.
    gate = Completer();
    final before = queue();
    before.enqueue([
      await owned('a', fix: StorageFix.backUpFirst),
    ], FlagSolution.backUp);
    before.enqueue([flag], FlagSolution.ignore);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final filed = jsonDecode((await store.getAppState('fix_queue_v1'))!);
    expect([for (final r in filed) r['solution']], ['backUp', 'ignore']);

    gate = null;
    final after = queue();
    await after.resume();
    await drained(after);

    expect(refreshes, greaterThan(0));
    expect(await IgnoredBucketKeys(store).read(), contains(object.key));
    expect(after.isResolved(flag), isTrue);
    expect(jsonDecode((await store.getAppState('fix_queue_v1'))!), isEmpty);
  });

  test('a likely duplicate is renamed one at a time, ignored in bulk', () {
    final flag = Flag.bucket(
      FlaggedObject(
        object: BucketObject(
          targetId: 't',
          key: 'originals/x.jpg',
          size: 1,
          lastModified: DateTime(2026),
        ),
        kind: FlagKind.offProtocol,
        likelyDuplicateOf: 'originals/y.jpg',
      ),
    );
    expect(flag.solutions, [FlagSolution.ignore, FlagSolution.rename]);
    expect(flag.batchable(FlagSolution.ignore), isTrue);
    expect(flag.batchable(FlagSolution.rename), isFalse);
  });
}

class _RecordingOptimizer extends StorageOptimizer {
  _RecordingOptimizer({
    required super.store,
    required super.thumbnails,
    required super.library,
    required super.backUp,
    required this.onApply,
  });

  final void Function(
    List<StorageItem> items,
    void Function(String localId)? onPrepared,
  )
  onApply;

  @override
  Future<StorageFixResult> apply(
    List<StorageItem> items, {
    void Function(String localId, StorageItemOutcome outcome)? onItem,
    void Function(String localId)? onPrepared,
    void Function(String localId, FixAction action)? onStep,
    bool deferDeletes = false,
  }) async {
    onApply(items, onPrepared);
    for (final i in items) {
      onItem?.call(i.record.localId, StorageItemOutcome.freed);
    }
    return const StorageFixResult();
  }
}

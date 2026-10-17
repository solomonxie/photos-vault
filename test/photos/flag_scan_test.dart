import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/fix_queue.dart';
import 'package:photos_vault/photos/flag_scan.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/photos/storage_advice.dart';
import 'package:photos_vault/photos/storage_optimizer.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:photos_vault/upload/bucket_flagged.dart';
import 'package:photos_vault/vault/hidden_repair.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';

/// Says every orphan is gone and changes nothing: a fixer the detector
/// disagrees with.
class _ClaimsDone extends BucketFixer {
  _ClaimsDone({required super.store, required super.targetsStore})
    : super(passphrases: () async => const []);

  @override
  Future<FixResult> removeOrphan(FlaggedObject f) async =>
      const FixResult(FixOutcome.removed);
}

void main() {
  late Directory tempDir;
  late FakeAssetRecordStore store;
  late BackupTargetsStore targets;

  const thumb = 'photos-vault/thumbnails/20260101120000_orphan.jpg';

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('pv_flag_scan_');
    store = FakeAssetRecordStore();
    targets = BackupTargetsStore(store: FakeSecureStore());
  });
  tearDown(() => tempDir.delete(recursive: true));

  StorageAdvisor advisor() => StorageAdvisor(
    store: store,
    measure: (r) async => AssetMeasure(
      bytes: 60 * 1024 * 1024,
      name: '${r.localId}.heic',
      appOwned: false,
    ),
  );

  FixQueue queue({BucketFixer? fixer}) => FixQueue(
    store: store,
    advisor: advisor(),
    optimizer: StorageOptimizer(
      store: store,
      thumbnails: ThumbnailCache(
        store: store,
        directory: () async => tempDir,
        encode: (_) async => Uint8List.fromList([1]),
      ),
      library: PhotoLibraryService(store: FakeAssetRecordStore()),
      backUp: (_) async {},
    ),
    fixer:
        fixer ??
        BucketFixer(
          store: store,
          targetsStore: targets,
          passphrases: () async => const [],
        ),
    refreshBucket: () async {},
  );

  FlagScan scanOver(FixQueue q, {Future<bool> Function()? relist}) => FlagScan(
    store: store,
    targetsStore: targets,
    advisor: q.advisor,
    queue: q,
    relist: relist ?? () async => true,
  );

  Future<void> listed(Map<String, int> sizes) =>
      store.replaceBucketObjects('t', [
        for (final MapEntry(:key, :value) in sizes.entries)
          BucketObject(
            targetId: 't',
            key: key,
            size: value,
            lastModified: DateTime(2026),
          ),
      ]);

  /// A big backed-up camera-roll photo: Optimize is on offer.
  Future<void> big(String id, {bool hidden = false}) async {
    await store.upsert(
      localId: id,
      contentHash: id,
      platform: 'ios',
      libraryId: 'lib-$id',
      width: 6000,
      height: 4000,
      passcodeHash: hidden ? 'tag' : null,
      isHidden: hidden,
    );
    await store.updateDerivative(
      id,
      DerivativeKind.original,
      DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'photos-vault/originals/$id.heic',
        backedUpHash: 'hash-$id',
      ),
    );
  }

  Future<void> drained(FixQueue q) async {
    while (q.running) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('one scan lists every kind, and a relaunch shows it without '
      'scanning again', () async {
    await big('big');
    await listed({thumb: 10, 'photos-vault/originals/big.heic': 10});
    final first = scanOver(queue());
    await first.open();
    await first.run();
    final ids = first.result.flags.map((f) => f.id).toList();
    expect(ids, containsAll(['asset:big', 'bucket:t|$thumb']));

    var relisted = 0;
    final again = scanOver(
      queue(),
      relist: () async {
        relisted++;
        return true;
      },
    );
    await again.open();

    expect(again.result.flags.map((f) => f.id), ids);
    expect(again.running, isFalse, reason: 'nothing it read has moved');
    expect(relisted, 0);
  });

  test('a fixed item stays off the list across a relaunch, until it is '
      'found again from new facts', () async {
    await listed({thumb: 10});
    final q = queue(
      fixer: _ClaimsDone(store: store, targetsStore: targets),
    );
    final scan = scanOver(q);
    await scan.open();
    await scan.run();
    final orphan = scan.result.flags.single;

    q.enqueue([orphan], FlagSolution.removeThumbnail);
    await drained(q);
    expect(q.isResolved(orphan), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 3));
    await scan.run();
    expect(scan.result.flags.single.id, orphan.id, reason: 'still detected');
    expect(q.isResolved(scan.result.flags.single), isTrue);

    final relaunched = queue(
      fixer: _ClaimsDone(store: store, targetsStore: targets),
    );
    await relaunched.loadKept();
    final rescan = scanOver(relaunched);
    await rescan.open();
    await rescan.run();
    expect(relaunched.isResolved(rescan.result.flags.single), isTrue);

    // The bucket now holds another file under that name: a new finding.
    await store.replaceBucketObjects('t', [
      BucketObject(
        targetId: 't',
        key: thumb,
        size: 99,
        lastModified: DateTime(2026, 2),
      ),
    ]);
    await rescan.run();
    expect(relaunched.isResolved(rescan.result.flags.single), isFalse);
  });

  test('a failure is still said after a relaunch', () async {
    await listed({thumb: 10});
    final q = queue();
    final scan = scanOver(q);
    await scan.open();
    await scan.run();
    final orphan = scan.result.flags.single;
    // No bucket set up: the fix fails.
    q.enqueue([orphan], FlagSolution.removeThumbnail);
    await drained(q);
    expect(q.failedBefore(orphan.id), isTrue);

    final relaunched = queue();
    await relaunched.loadKept();
    expect(relaunched.failedBefore(orphan.id), isTrue);
  });

  test('a rescan keeps the last list until the new one lands', () async {
    await listed({thumb: 10});
    final gate = Completer<bool>();
    var gated = false;
    final scan = scanOver(
      queue(),
      relist: () => gated ? gate.future : Future.value(true),
    );
    await scan.open();
    await scan.run();
    expect(scan.result.flags, hasLength(1));

    gated = true;
    final seen = <int>[];
    scan.addListener(() => seen.add(scan.result.flags.length));
    final running = scan.run(relist: true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(scan.running, isTrue);
    expect(scan.result.flags, hasLength(1));
    gate.complete(true);
    await running;

    expect(seen, everyElement(1), reason: 'never emptied in between');
  });

  test('runs asked for at once never overlap', () async {
    await listed({thumb: 10});
    var inFlight = 0;
    var most = 0;
    var calls = 0;
    final scan = scanOver(
      queue(),
      relist: () async {
        calls++;
        most = ++inFlight > most ? inFlight : most;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        inFlight--;
        return true;
      },
    );
    await Future.wait([
      scan.run(relist: true),
      scan.run(relist: true),
      scan.run(relist: true),
    ]);

    expect(most, 1);
    expect(calls, 2, reason: 'the asks made while one ran share one more');
  });

  test('while uploads run, a moved input waits the longer gap; once they '
      'stop, the usual one', () async {
    await big('photo:a');
    await listed({thumb: 10});
    var now = DateTime(2026, 10, 1, 12);
    final uploading = ValueNotifier(true);
    final q = queue();
    final scan = FlagScan(
      store: store,
      targetsStore: targets,
      advisor: q.advisor,
      queue: q,
      relist: () async => true,
      uploading: uploading,
      now: () => now,
    );
    var runs = 0;
    var was = false;
    scan.addListener(() {
      if (scan.running && !was) runs++;
      was = scan.running;
    });
    await scan.run();
    final ran = runs;

    Future<void> moveAndAsk(Duration later) async {
      await store.setFavorite(
        'photo:a',
        !(await store.getByLocalId('photo:a'))!.isFavorite,
      );
      now = now.add(later);
      await scan.refreshIfChanged();
    }

    await moveAndAsk(const Duration(minutes: 1));
    expect(runs, ran, reason: 'within the uploading gap');
    await moveAndAsk(FlagScan.uploadingGap);
    expect(runs, ran + 1);

    uploading.value = false;
    await moveAndAsk(const Duration(seconds: 20));
    expect(runs, ran + 2);
  });

  test('hidden photos are never listed, from a scan or from the saved '
      'result', () async {
    await big('plain');
    await big('secret', hidden: true);
    // An exact copy of the hidden one, and the one-time repair naming it.
    await big('twin');
    await store.updateDerivative(
      'twin',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'photos-vault/originals/twin.heic',
        backedUpHash: 'hash-secret',
      ),
    );
    await store.setAppState(
      HiddenRepair.stateKey,
      jsonEncode([
        const RepairItem(
          'secret',
          RepairKind.carrierStem,
          hidden: false,
        ).toJson(),
      ]),
    );
    await listed({'photos-vault/originals/plain.heic': 10});
    final q = queue();
    final scan = scanOver(q);
    await scan.open();
    await scan.run();

    String? idOf(Flag f) => f.record?.localId;
    expect(scan.result.flags.map(idOf), isNot(contains('secret')));
    expect(scan.result.review, isEmpty);

    // Hidden after the scan: the saved result drops it too.
    await store.setHidden('plain', true);
    await store.setPasscodeHash('plain', 'tag');
    final relaunched = scanOver(queue());
    await relaunched.open();
    expect(relaunched.result.flags.map(idOf), isNot(contains('plain')));
    expect(relaunched.result.flags.map(idOf), isNot(contains('secret')));
    await relaunched.run();
    expect(relaunched.result.flags.map(idOf), isNot(contains('plain')));
  });

  group('storage: the fix leaves nothing for the detector', () {
    test('Optimize: an optimized photo is not offered again', () async {
      await big('a');
      final record = (await store.getByLocalId('a'))!;
      expect(
        adviseOn(
          record: record,
          bytes: 60 << 20,
          name: 'a.heic',
          appOwned: true,
        ),
        isNotNull,
      );
      await store.setLocalOptimized('a', true);
      expect(
        adviseOn(
          record: (await store.getByLocalId('a'))!,
          bytes: 20 << 20,
          name: 'a.heic',
          appOwned: true,
        ),
        isNull,
      );
    });

    test('Optimize that found nothing smaller is not offered again', () async {
      await big('a');
      final a = advisor();
      await a.scan();
      expect((await a.cached()).items, isNotEmpty);
      await a.markSmallestAlready(['a']);
      expect((await a.cached()).items, isEmpty);
    });

    test('Optimize in the bucket is not offered again, on the phone or '
        'cloud-only', () async {
      await big('a');
      await store.upsert(
        localId: 'c',
        contentHash: 'c',
        platform: 'ios',
        width: 6000,
        height: 4000,
      );
      await store.updateDerivative(
        'c',
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'photos-vault/originals/c.heic',
        ),
      );
      await store.setLocalDeleted('c', true);
      await listed({
        'photos-vault/originals/a.heic': 60 << 20,
        'photos-vault/originals/c.heic': 60 << 20,
      });
      final a = advisor();
      await a.scan();
      expect(
        (await a.cached()).items.single.fixes,
        contains(StorageFix.optimizeRemote),
      );
      expect(await a.cloudOnly(), hasLength(1));

      await a.markRemoteOptimized('a');
      await a.markRemoteOptimized('c');
      expect(
        (await a.cached()).items.single.fixes,
        isNot(contains(StorageFix.optimizeRemote)),
      );
      expect(await a.cloudOnly(), isEmpty);
    });

    test('Remove Duplicates: the copy binned, nothing is offered', () async {
      await big('a');
      await big('b');
      for (final id in ['a', 'b']) {
        await store.updateDerivative(
          id,
          DerivativeKind.original,
          DerivativeState(
            status: UploadStatus.uploaded,
            destinationKey: 'photos-vault/originals/$id.heic',
            backedUpHash: 'same',
          ),
        );
      }
      final a = advisor();
      final found = await a.duplicates();
      expect(found, hasLength(1));

      await store.softDelete(found.single.record.localId);
      expect(await a.duplicates(), isEmpty);
    });
  });
}

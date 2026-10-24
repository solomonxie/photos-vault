import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/photos/record_fixer.dart';
import 'package:photos_vault/photos/storage_advice.dart';
import 'package:photos_vault/photos/storage_optimizer.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/photos/fix_queue.dart';
import 'package:photos_vault/photos/flag_scan.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:photos_vault/upload/bucket_flagged.dart';
import 'package:photos_vault/viewer/flagged_action_screen.dart';
import 'package:photos_vault/vault/hidden_repair.dart';
import 'package:photos_vault/viewer/flagged_items_screen.dart';

import '../settings/fake_secure_store.dart';

import '../support/fake_asset_record_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('pv_flagged_ui_'));
  tearDown(() => tempDir.delete(recursive: true));

  /// Two backed-up camera-roll photos — one large, one not — and a large
  /// one whose upload failed.
  Future<FakeAssetRecordStore> seeded() async {
    final store = FakeAssetRecordStore();
    Future<void> add(
      String id, {
      required UploadStatus status,
      int? width,
      int? height,
    }) async {
      await store.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        libraryId: 'lib-$id',
        width: width,
        height: height,
      );
      await store.updateDerivative(
        id,
        DerivativeKind.original,
        DerivativeState(status: status),
      );
      await store.setThumbnailPath(
        id,
        (File('${tempDir.path}/$id.jpg')..writeAsBytesSync([1])).path,
      );
    }

    await add('big', status: UploadStatus.uploaded, width: 6000, height: 4000);
    await add('small', status: UploadStatus.uploaded);
    await add('unsent', status: UploadStatus.failed);
    return store;
  }

  StorageAdvisor advisorOver(FakeAssetRecordStore store) => StorageAdvisor(
    store: store,
    measure: (r) async => AssetMeasure(
      bytes: switch (r.localId) {
        'big' => 60 * 1024 * 1024,
        'unsent' => 50 * 1024 * 1024,
        _ => 1024,
      },
      name: '${r.localId}.heic',
      appOwned: false,
    ),
  );

  Future<List<String>> open(
    WidgetTester tester,
    FakeAssetRecordStore store, {
    RecordFixer? records,
  }) async {
    final deleted = <String>[];
    final targets = BackupTargetsStore(store: FakeSecureStore());
    final advisor = advisorOver(store);
    final queue = FixQueue(
      store: store,
      advisor: advisor,
      optimizer: StorageOptimizer(
        store: store,
        thumbnails: ThumbnailCache(
          store: store,
          directory: () async => tempDir,
          encode: (_) async => Uint8List.fromList([1]),
        ),
        library: PhotoLibraryService(
          store: store,
          deleteAssets: (ids) async {
            deleted.addAll(ids);
            return ids;
          },
        ),
        backUp: (_) async {},
      ),
      fixer: BucketFixer(
        store: store,
        targetsStore: targets,
        passphrases: () async => const [],
      ),
      refreshBucket: () async {},
      records: records,
    );
    await tester.pumpWidget(
      _wrap(
        FlaggedItemsScreen(
          store: store,
          targetsStore: targets,
          advisor: advisor,
          queue: queue,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    return deleted;
  }

  Finder action(String solution) =>
      find.byKey(ValueKey('flagged-action-$solution'));

  testWidgets('actions, not files: each says what it does, to how many', (
    tester,
  ) async {
    await open(tester, await seeded());

    expect(find.text('1 item to fix'), findsOneWidget);
    expect(find.text('ON THIS IPHONE'), findsOneWidget);
    expect(action('optimize'), findsOneWidget);
    // Not backed up yet is the backup queue's business, not an action here.
    expect(action('backUp'), findsNothing);
    // Nothing here ever deletes a local copy, and a fine photo isn't listed.
    expect(action('removeFromDevice'), findsNothing);
    expect(find.text('big.heic'), findsNothing, reason: 'files are a tap in');
  });

  testWidgets('archived and backed up: offered off this iPhone, the rest '
      'not', (tester) async {
    final store = await seeded();
    await store.setArchived(['small', 'unsent'], true);
    await open(tester, store);

    final row = find.byKey(const ValueKey('flagged-archived-on-phone'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('1 photo')),
      findsOneWidget,
      reason: 'unsent is archived but not in the bucket yet',
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(FlaggedActionScreen), findsOneWidget);
  });

  testWidgets('Rescan keeps the list on screen until the new one lands', (
    tester,
  ) async {
    final store = await seeded();
    final targets = BackupTargetsStore(store: FakeSecureStore());
    final advisor = advisorOver(store);
    final queue = FixQueue(
      store: store,
      advisor: advisor,
      optimizer: StorageOptimizer(
        store: store,
        thumbnails: ThumbnailCache(
          store: store,
          directory: () async => tempDir,
          encode: (_) async => Uint8List.fromList([1]),
        ),
        library: PhotoLibraryService(store: store),
        backUp: (_) async {},
      ),
      fixer: BucketFixer(
        store: store,
        targetsStore: targets,
        passphrases: () async => const [],
      ),
      refreshBucket: () async {},
    );
    var gate = Completer<bool>()..complete(true);
    final scan = FlagScan(
      store: store,
      targetsStore: targets,
      advisor: advisor,
      queue: queue,
      relist: () => gate.future,
    );
    await tester.pumpWidget(
      _wrap(
        FlaggedItemsScreen(
          store: store,
          targetsStore: targets,
          advisor: advisor,
          queue: queue,
          scan: scan,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(action('optimize'), findsOneWidget);

    gate = Completer<bool>();
    await tester.tap(find.text('Rescan'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(scan.running, isTrue);
    expect(action('optimize'), findsOneWidget);
    expect(find.text('1 item to fix'), findsOneWidget);

    gate.complete(true);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(scan.running, isFalse);
    expect(action('optimize'), findsOneWidget);
    scan.dispose();
  });

  testWidgets('what the one-time repair listed is shown as information, '
      'never a hidden photo', (tester) async {
    final store = await seeded();
    await store.setAppState(
      HiddenRepair.stateKey,
      jsonEncode([
        const RepairItem('big', RepairKind.carrierStem, hidden: false).toJson(),
        const RepairItem(
          'manual:vault-x',
          RepairKind.twoCarriers,
          hidden: true,
        ).toJson(),
      ]),
    );

    await open(tester, store);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('flagged-review-big')),
      200,
    );

    expect(find.text('TO LOOK AT'), findsOneWidget);
    expect(find.byKey(const ValueKey('flagged-review-big')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('flagged-review-manual:vault-x')),
      findsNothing,
    );
  });

  testWidgets('while photos are still backing up, Optimize waits so they '
      'all come at once', (tester) async {
    final store = await seeded();
    await store.updateDerivative(
      'unsent',
      DerivativeKind.original,
      const DerivativeState(status: UploadStatus.pending),
    );
    await open(tester, store);

    expect(action('optimize'), findsNothing);
    expect(find.text('Nothing to fix'), findsOneWidget);
    expect(
      find.text(
        "1 photo is still backing up. Optimize is offered once it's done.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('an action opens onto its items, all selected, with one '
      'button for them', (tester) async {
    await open(tester, await seeded());

    await tester.tap(action('optimize'));
    await tester.pumpAndSettle();

    expect(find.text('big.heic'), findsOneWidget);
    expect(find.text('Optimize Space · 1'), findsOneWidget);
    expect(find.text('Deselect All'), findsOneWidget);
  });

  testWidgets('unticking leaves an item out of the run', (tester) async {
    await open(tester, await seeded());

    await tester.tap(action('optimize'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('big.heic'));
    await tester.pumpAndSettle();

    expect(find.text('Optimize Space · 0'), findsOneWidget);
    expect(find.text('Select All'), findsOneWidget);
  });

  testWidgets('Hide from List takes a photo off the list for good', (
    tester,
  ) async {
    final store = await seeded();
    await open(tester, store);

    await tester.tap(action('optimize'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('flagged-hide')));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));

    expect(action('optimize'), findsNothing);
    expect(await store.getAppState('flag_kept_v1'), contains('asset:big'));
  });

  testWidgets('a bucket action stays open on its files', (tester) async {
    final store = await seeded();
    await store.replaceBucketObjects('t', [
      BucketObject(
        targetId: 't',
        key: 'photos-vault/originals/IMG_0042.PNG',
        size: 10,
        lastModified: DateTime(2025),
      ),
    ]);
    await open(tester, store);

    await tester.tap(action('rename'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(find.text('IMG_0042.PNG'), findsOneWidget);
  });

  testWidgets('Optimize in bucket starts unticked and asks before it '
      'replaces an original for good', (tester) async {
    final store = FakeAssetRecordStore();
    await store.upsert(localId: 'c', contentHash: 'c', platform: 'ios');
    await store.setLocalDeleted('c', true);
    final record = (await store.getByLocalId('c'))!;
    final queue = FixQueue(
      store: store,
      advisor: advisorOver(store),
      optimizer: StorageOptimizer(
        store: store,
        thumbnails: ThumbnailCache(
          store: store,
          directory: () async => tempDir,
          encode: (_) async => Uint8List.fromList([1]),
        ),
        library: PhotoLibraryService(store: store),
        backUp: (_) async {},
      ),
      fixer: BucketFixer(
        store: store,
        targetsStore: BackupTargetsStore(store: FakeSecureStore()),
        passphrases: () async => const [],
      ),
      refreshBucket: () async {},
    );
    final flag = Flag.storage(
      StorageItem(
        record: record,
        bytes: 1,
        name: 'cloud.heic',
        appOwned: false,
        issues: const {StorageIssue.largeFile},
        fixes: const [StorageFix.optimizeRemote],
      ),
    );
    await tester.pumpWidget(
      _wrap(
        FlaggedActionScreen(
          solution: FlagSolution.optimizeRemote,
          flags: [flag],
          queue: queue,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Optimize Space · 0'), findsOneWidget);
    await tester.tap(find.text('cloud.heic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Optimize Space · 1'));
    await tester.pumpAndSettle();

    expect(find.textContaining("can't be undone"), findsOneWidget);
    expect(
      find.textContaining('1 of them has no other full-quality copy'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(queue.jobs, isEmpty);
  });

  testWidgets('cloud-only records without a thumbnail, or without any '
      'bucket, are actions of their own', (tester) async {
    final store = await seeded();
    Future<void> cloudOnly(String id, String key, {bool video = false}) async {
      await store.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        isVideo: video,
      );
      await store.updateDerivative(
        id,
        DerivativeKind.original,
        DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
      );
      await store.setLocalDeleted(id, true);
    }

    await cloudOnly('clip', 'photos-vault/originals/clip.mov', video: true);
    await cloudOnly('old', 'photos-vault2/originals/old.jpg');
    await store.replaceBucketObjects('t', [
      BucketObject(
        targetId: 't',
        key: 'photos-vault/originals/clip.mov',
        size: 10,
        lastModified: DateTime(2025),
      ),
    ]);
    final removed = <String>[];
    await open(
      tester,
      store,
      records: RecordFixer(
        store: store,
        thumbnail: (_) async => null,
        inPhotos: (_) async => false,
        liveOriginal: (_, _) async => null,
        remove: (r) async {
          removed.add(r.localId);
          await store.remove(r.localId);
          return true;
        },
      ),
    );

    expect(action('makeThumbnail'), findsOneWidget);
    expect(action('removeFromLibrary'), findsOneWidget);
    expect(action('getFromPhotos'), findsNothing, reason: 'not in Photos');
    expect(find.text('1 photo is missing from the bucket'), findsOneWidget);

    await tester.tap(action('removeFromLibrary'));
    await tester.pumpAndSettle();
    expect(
      find.text('Not in any bucket set up now, and not on this iPhone'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('flagged-run')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining("They're removed from this app for good"),
      findsWidgets,
    );
    await tester.tap(find.text('Remove from Library').last);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(removed, ['old']);
    expect(await store.getByLocalId('old'), isNull);
  });
}

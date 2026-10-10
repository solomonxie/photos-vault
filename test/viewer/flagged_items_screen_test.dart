import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/photos/storage_advice.dart';
import 'package:photos_vault/photos/storage_optimizer.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/photos/fix_queue.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:photos_vault/upload/bucket_flagged.dart';
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
  /// one that was never uploaded.
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
    await add('unsent', status: UploadStatus.pending);
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
    FakeAssetRecordStore store,
  ) async {
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
}

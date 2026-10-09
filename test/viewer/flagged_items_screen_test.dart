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

    await add('big', status: UploadStatus.uploaded);
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

  testWidgets('a chip per problem, a button per solution', (tester) async {
    await open(tester, await seeded());

    expect(find.text('3 items to fix'), findsOneWidget);
    expect(find.text('Frees up to 60.0 MB on this phone'), findsOneWidget);
    expect(find.text('All 3'), findsOneWidget);
    expect(find.text('On device 2'), findsOneWidget);
    expect(find.text('Large file 2'), findsOneWidget);
    expect(find.text('Remove from Device · 2'), findsOneWidget);
    expect(find.text('Back Up First · 1'), findsOneWidget);
  });

  testWidgets('a chip narrows the solutions to that problem', (tester) async {
    await open(tester, await seeded());

    await tester.tap(find.text('Large file 2'));
    await tester.pumpAndSettle();

    expect(find.text('Remove from Device · 1'), findsOneWidget);
    expect(find.text('Back Up First · 1'), findsOneWidget);
  });

  testWidgets('fixing a batch drains it from the list', (tester) async {
    final deleted = await open(tester, await seeded());

    await tester.tap(find.text('Remove from Device · 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove from Device').last);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(deleted, unorderedEquals(['lib-big', 'lib-small']));
    expect(find.text('1 item to fix'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.textContaining('Remove from Device'), findsNothing);
  });
}

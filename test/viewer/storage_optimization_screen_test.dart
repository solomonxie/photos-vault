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
import 'package:photos_vault/viewer/storage_optimization_screen.dart';

import '../support/fake_asset_record_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('pv_storage_ui_'));
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

  StorageOptimizer optimizerOver(
    FakeAssetRecordStore store, {
    List<String>? deleted,
    List<AssetRecord>? queued,
  }) => StorageOptimizer(
    store: store,
    thumbnails: ThumbnailCache(
      store: store,
      directory: () async => tempDir,
      encode: (_) async => Uint8List.fromList([1]),
    ),
    library: PhotoLibraryService(
      store: store,
      deleteAssets: (ids) async {
        deleted?.addAll(ids);
        return ids;
      },
    ),
    backUp: (records) async => queued?.addAll(records),
  );

  Future<void> open(
    WidgetTester tester,
    FakeAssetRecordStore store, {
    StorageOptimizer? optimizer,
  }) async {
    await tester.pumpWidget(
      _wrap(
        StorageOptimizationScreen(
          advisor: advisorOver(store),
          optimizer: optimizer ?? optimizerOver(store),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('summarises what can be reclaimed and lists a chip per problem', (
    tester,
  ) async {
    await open(tester, await seeded());

    expect(find.text('Free up to 60.0 MB'), findsOneWidget);
    expect(find.text('3 items, using 110.0 MB on this device'), findsOneWidget);
    expect(find.text('All 3'), findsOneWidget);
    expect(find.text('On device 2'), findsOneWidget);
    expect(find.text('Large file 2'), findsOneWidget);
    // A backup problem belongs to the sync queue, not to this page.
    expect(find.textContaining('Not backed up'), findsNothing);
  });

  testWidgets('offers each photo the fix that suits it', (tester) async {
    await open(tester, await seeded());

    expect(find.text('Remove from Device'), findsNWidgets(2));
    expect(find.text('Back Up First'), findsOneWidget);
  });

  testWidgets('a chip filters the list down to that problem', (tester) async {
    await open(tester, await seeded());

    await tester.tap(find.text('Large file 2'));
    await tester.pumpAndSettle();

    expect(find.text('Back Up First'), findsOneWidget);
    expect(find.text('Remove from Device'), findsOneWidget);
  });

  testWidgets('a single card\'s fix applies to that photo alone', (
    tester,
  ) async {
    final store = await seeded();
    final deleted = <String>[];
    await open(
      tester,
      store,
      optimizer: optimizerOver(store, deleted: deleted),
    );

    await tester.tap(find.text('Remove from Device').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Optimize').last);
    await tester.pumpAndSettle();

    expect(deleted, ['lib-big']);
    expect((await store.getByLocalId('big'))!.localDeleted, isTrue);
    expect((await store.getByLocalId('small'))!.localDeleted, isFalse);
  });

  testWidgets('select mode applies every item\'s own fix in one go', (
    tester,
  ) async {
    final store = await seeded();
    final deleted = <String>[];
    final queued = <AssetRecord>[];
    await open(
      tester,
      store,
      optimizer: optimizerOver(store, deleted: deleted, queued: queued),
    );

    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();

    expect(find.text('3 selected · frees up to 60.0 MB'), findsOneWidget);

    await tester.tap(find.text('Optimize').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Optimize').last);
    await tester.pumpAndSettle();

    expect(deleted, ['lib-big', 'lib-small']);
    expect(queued.single.localId, 'unsent');
    expect(find.textContaining('Freed '), findsOneWidget);
  });

  testWidgets('opens on the last scan instead of walking the library again', (
    tester,
  ) async {
    final store = await seeded();
    var measures = 0;
    StorageAdvisor advisor() => StorageAdvisor(
      store: store,
      measure: (r) async {
        measures++;
        return AssetMeasure(
          bytes: r.localId == 'big' ? 60 * 1024 * 1024 : 1024,
          name: '${r.localId}.heic',
          appOwned: false,
        );
      },
    );

    for (var visit = 0; visit < 2; visit++) {
      await tester.pumpWidget(
        _wrap(
          StorageOptimizationScreen(
            advisor: advisor(),
            optimizer: optimizerOver(store),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Remove from Device'), findsNWidgets(2));
    }

    // Three photos measured on the first visit, none on the second.
    expect(measures, 3);
    expect(find.textContaining('Scanned '), findsOneWidget);
  });

  testWidgets('rescan walks the library again on demand', (tester) async {
    final store = await seeded();
    var measures = 0;
    await tester.pumpWidget(
      _wrap(
        StorageOptimizationScreen(
          advisor: StorageAdvisor(
            store: store,
            measure: (_) async {
              measures++;
              return const AssetMeasure(
                bytes: 1024,
                name: 'a.heic',
                appOwned: false,
              );
            },
          ),
          optimizer: optimizerOver(store),
        ),
      ),
    );
    await tester.pumpAndSettle();
    measures = 0;

    await tester.tap(find.text('Rescan'));
    await tester.pumpAndSettle();

    expect(measures, 3);
  });

  testWidgets('says so when there is nothing left to optimize', (tester) async {
    final store = FakeAssetRecordStore();
    await tester.pumpWidget(
      _wrap(
        StorageOptimizationScreen(
          advisor: advisorOver(store),
          optimizer: optimizerOver(store),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing to optimize'), findsOneWidget);
    expect(find.text('Select'), findsNothing);
  });
}

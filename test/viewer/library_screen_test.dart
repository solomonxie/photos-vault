import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/photos/demo_assets_service.dart';
import 'package:bring_your_own_photos/photos/demo_seed_store.dart';
import 'package:bring_your_own_photos/photos/manual_add.dart';
import 'package:bring_your_own_photos/photos/person_store.dart';
import 'package:bring_your_own_photos/photos/photo_library_service.dart';
import 'package:bring_your_own_photos/photos/thumbnail_cache.dart';
import 'package:bring_your_own_photos/settings/backup_targets_store.dart';
import 'package:bring_your_own_photos/settings/s3_backup_target.dart';
import 'package:bring_your_own_photos/storage/album_store.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:bring_your_own_photos/storage/asset_record_store.dart';
import 'package:bring_your_own_photos/upload/backup_coordinator.dart';
import 'package:bring_your_own_photos/upload/s3_uploader.dart';
import 'package:bring_your_own_photos/viewer/asset_grid.dart';
import 'package:bring_your_own_photos/viewer/detail_screen.dart';
import 'package:bring_your_own_photos/viewer/library_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_ai_analysis_store.dart';
import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';
import '../support/fake_sync_job_store.dart';

// Never touches the real `background_downloader` platform channel — this
// screen's tests only cover the no-targets-configured path, where it's
// never actually invoked.
class _UnusedS3Uploader implements S3Uploader {
  @override
  Future<bool> put({
    required String filePath,
    required String key,
    required S3BackupTarget target,
  }) => throw UnimplementedError();
}

class _FakeS3Uploader implements S3Uploader {
  _FakeS3Uploader(this.result);
  final bool result;

  @override
  Future<bool> put({
    required String filePath,
    required String key,
    required S3BackupTarget target,
  }) async => result;
}

// Never touches the real asset bundle / disk — inserts straight into the
// given store instead, like the real service would after copying bytes out.
class _FakeDemoAssetsService implements DemoAssetsService {
  _FakeDemoAssetsService(this.store);
  final AssetRecordStore store;

  @override
  ManualAddService get manualAddService => throw UnimplementedError();

  @override
  AlbumStore get albumStore => throw UnimplementedError();

  @override
  PersonStore get personStore => throw UnimplementedError();

  @override
  Future<List<AssetRecord>> addAll() async => [
    await store.upsert(
      localId: 'manual:demo1',
      contentHash: 'demo1',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/demo_photo_1.jpg',
    ),
  ];
}

// Never decodes or writes a real image: `ensureFor` short-circuits on the
// null encode, so no widget test ever does real file I/O — which never
// completes under `testWidgets`' fake async.
ThumbnailCache _noThumbnails(AssetRecordStore store) =>
    ThumbnailCache(store: store, encode: (_) async => null);

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

// Marked as already seeded so LibraryScreen's one-time auto-seed never
// fires here — these tests set up their own records/albums explicitly and
// assert on exact contents/counts.
//
// The flag lives in the asset store itself (see [DemoSeedStore]), so a
// caller that also wants specific records passes the same store in.
DemoSeedStore _alreadySeededStore([AssetRecordStore? store]) {
  final recordStore = store ?? FakeAssetRecordStore();
  return DemoSeedStore(recordStore: recordStore)..markSeeded();
}

void main() {
  testWidgets('shows the empty placeholder with no manual adds yet', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: _alreadySeededStore(),
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: FakeSyncJobStore(),
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
          backupTargetsStore: targetsStore,
          backupCoordinator: BackupCoordinator(
            targetsStore: targetsStore,
            recordStore: recordStore,
            s3Uploader: _UnusedS3Uploader(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No Photos Yet'), findsOneWidget);
  });

  testWidgets(
    'syncs the real camera roll in and lists it alongside manual adds (T2.1)',
    (tester) async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      final recordStore = FakeAssetRecordStore();
      final photoLibraryService = PhotoLibraryService(
        store: recordStore,
        requestPermission: () async => PermissionState.authorized,
        listAllAssets: () async => [
          AssetEntity(
            id: 'roll1',
            typeInt: AssetType.image.index,
            width: 100,
            height: 100,
          ),
        ],
        // Backing up a synced asset needs its file, resolved via the real
        // plugin (`AssetEntity.file`) — untouchable in a widget test. Stub it
        // out so the sync completes without ever hitting the platform channel.
        loadEntity: (_) async => null,
      );

      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
            demoSeedStore: _alreadySeededStore(),
            assetRecordStore: recordStore,
            thumbnailCache: _noThumbnails(recordStore),
            syncJobStore: FakeSyncJobStore(),
            albumStore: FakeAlbumStore(),
            personStore: FakePersonStore(),
            backupTargetsStore: targetsStore,
            backupCoordinator: BackupCoordinator(
              targetsStore: targetsStore,
              recordStore: recordStore,
              s3Uploader: _UnusedS3Uploader(),
            ),
            photoLibraryService: photoLibraryService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('photo:roll1')), findsOneWidget);
    },
  );

  testWidgets('lists a previously manually-added file as a grid tile', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    await recordStore.upsert(
      localId: 'manual:abc',
      contentHash: 'abc',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/library_screen_test.jpg',
    );

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: _alreadySeededStore(),
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: FakeSyncJobStore(),
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
          backupTargetsStore: targetsStore,
          backupCoordinator: BackupCoordinator(
            targetsStore: targetsStore,
            recordStore: recordStore,
            s3Uploader: _UnusedS3Uploader(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manual:abc')), findsOneWidget);
    // Not-yet-backed-up badge on the tile.
    expect(find.byType(StatusDot), findsOneWidget);
  });

  testWidgets('tapping a listed file opens the detail screen', (tester) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    await recordStore.upsert(
      localId: 'manual:abc',
      contentHash: 'abc',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/library_screen_test.jpg',
    );

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: _alreadySeededStore(),
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: FakeSyncJobStore(),
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
          backupTargetsStore: targetsStore,
          backupCoordinator: BackupCoordinator(
            targetsStore: targetsStore,
            recordStore: recordStore,
            s3Uploader: _UnusedS3Uploader(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('manual:abc')));
    // A couple of bounded pumps, not pumpAndSettle: DetailScreen's image
    // decode is real file I/O, which never resolves under testWidgets'
    // fake-async zone — we only need the push transition to finish, not
    // the image actually rendered.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(DetailScreen), findsOneWidget);
  });

  testWidgets(
    'deleting from the detail viewer asks for confirmation before soft-deleting',
    (tester) async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      final recordStore = FakeAssetRecordStore();
      await recordStore.upsert(
        localId: 'manual:abc',
        contentHash: 'abc',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/library_screen_test.jpg',
      );

      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
            demoSeedStore: _alreadySeededStore(),
            assetRecordStore: recordStore,
            thumbnailCache: _noThumbnails(recordStore),
            syncJobStore: FakeSyncJobStore(),
            albumStore: FakeAlbumStore(),
            personStore: FakePersonStore(),
            backupTargetsStore: targetsStore,
            backupCoordinator: BackupCoordinator(
              targetsStore: targetsStore,
              recordStore: recordStore,
              s3Uploader: _UnusedS3Uploader(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('manual:abc')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(DetailScreen), findsOneWidget);

      await tester.tap(find.byIcon(CupertinoIcons.trash));
      await tester.pumpAndSettle();
      expect(find.text('Delete this item?'), findsOneWidget);

      // Cancelling leaves the item alone and the viewer open.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(DetailScreen), findsOneWidget);
      expect((await recordStore.listAll()).single.isDeleted, isFalse);

      await tester.tap(find.byIcon(CupertinoIcons.trash));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.byType(DetailScreen), findsNothing);
      expect((await recordStore.listAll()).single.isDeleted, isTrue);
    },
  );

  testWidgets('tapping Add Files with nothing picked reports zero added', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    // Picker returns no files, so the tap handler completes without any
    // real File I/O — safe to drive through a normal (non-runAsync) pump.
    final manualAdd = ManualAddService(
      store: recordStore,
      picker: ({type = FileType.any, allowMultiple = false}) async => [],
    );

    // Import Photos now sits below Favorites/Cloud Backups/AI Settings/Reset
    // Demo in Utilities — tall surface so it's built by the lazy
    // CustomScrollView without needing a scroll.
    await tester.binding.setSurfaceSize(const Size(400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: _alreadySeededStore(),
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: FakeSyncJobStore(),
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
          backupTargetsStore: targetsStore,
          manualAddService: manualAdd,
          backupCoordinator: BackupCoordinator(
            targetsStore: targetsStore,
            recordStore: recordStore,
            s3Uploader: _UnusedS3Uploader(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import Photos'));
    await tester.pumpAndSettle();

    expect(find.text('Added 0 file(s), backed up 0.'), findsOneWidget);
  });

  testWidgets('tapping Try with Demo Photos adds and lists the demo asset', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: _alreadySeededStore(),
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: FakeSyncJobStore(),
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
          backupTargetsStore: targetsStore,
          demoAssetsService: _FakeDemoAssetsService(recordStore),
          backupCoordinator: BackupCoordinator(
            targetsStore: targetsStore,
            recordStore: recordStore,
            s3Uploader: _UnusedS3Uploader(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Try with Demo Photos'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manual:demo1')), findsOneWidget);
  });

  testWidgets(
    'a fresh install seeds demo photos automatically, without a manual tap',
    (tester) async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      final recordStore = FakeAssetRecordStore();
      final demoSeedStore = DemoSeedStore(recordStore: recordStore);

      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
            demoSeedStore: demoSeedStore,
            assetRecordStore: recordStore,
            thumbnailCache: _noThumbnails(recordStore),
            syncJobStore: FakeSyncJobStore(),
            albumStore: FakeAlbumStore(),
            personStore: FakePersonStore(),
            backupTargetsStore: targetsStore,
            demoAssetsService: _FakeDemoAssetsService(recordStore),
            backupCoordinator: BackupCoordinator(
              targetsStore: targetsStore,
              recordStore: recordStore,
              s3Uploader: _UnusedS3Uploader(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('manual:demo1')), findsOneWidget);
      expect(await demoSeedStore.hasSeeded(), isTrue);
    },
  );

  testWidgets('holding a tile starts selection mode with its batch actions', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    await recordStore.upsert(
      localId: 'manual:abc',
      contentHash: 'abc',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/library_screen_test.jpg',
    );

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: _alreadySeededStore(),
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: FakeSyncJobStore(),
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
          backupTargetsStore: targetsStore,
          backupCoordinator: BackupCoordinator(
            targetsStore: targetsStore,
            recordStore: recordStore,
            s3Uploader: _UnusedS3Uploader(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('manual:abc')));
    await tester.pumpAndSettle();

    expect(find.text('1 Selected'), findsOneWidget);
    for (final action in ['Add Tag', 'Set Place', 'Set Event', 'Adjust Date']) {
      expect(find.text(action), findsOneWidget);
    }

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('1 Selected'), findsNothing);
  });

  testWidgets('a batch edit applies one place to every selected photo', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    for (final id in ['manual:one', 'manual:two']) {
      await recordStore.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/$id.jpg',
      );
    }

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: _alreadySeededStore(),
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: FakeSyncJobStore(),
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
          backupTargetsStore: targetsStore,
          backupCoordinator: BackupCoordinator(
            targetsStore: targetsStore,
            recordStore: recordStore,
            s3Uploader: _UnusedS3Uploader(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const ValueKey('manual:one')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:two')));
    await tester.pumpAndSettle();
    expect(find.text('2 Selected'), findsOneWidget);

    await tester.tap(find.text('Set Place'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoSearchTextField).last, 'Kyoto');
    await tester.pump();
    await tester.tap(find.text('Use "Kyoto"'));
    await tester.pumpAndSettle();

    expect((await recordStore.getByLocalId('manual:one'))!.location, 'Kyoto');
    expect((await recordStore.getByLocalId('manual:two'))!.location, 'Kyoto');
  });

  // The removal itself is real file I/O, which never completes under
  // `testWidgets`' fake async — `ThumbnailCache`'s own (plain `test`) suite
  // covers that half. What's worth pinning here is the decision: who gets
  // offered the cloud-only option, and what the grid does afterwards.
  Future<void> pumpWithRecord(
    WidgetTester tester,
    FakeAssetRecordStore recordStore,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: _alreadySeededStore(),
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: FakeSyncJobStore(),
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
          backupTargetsStore: targetsStore,
          backupCoordinator: BackupCoordinator(
            targetsStore: targetsStore,
            recordStore: recordStore,
            s3Uploader: _UnusedS3Uploader(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('deleting a backed-up photo offers to keep the cloud copy', (
    tester,
  ) async {
    final recordStore = FakeAssetRecordStore();
    await recordStore.upsert(
      localId: 'manual:abc',
      contentHash: 'abc',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/backed-up.jpg',
    );
    await recordStore.updateDerivative(
      'manual:abc',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'originals/manual_abc.jpg',
      ),
    );
    await pumpWithRecord(tester, recordStore);

    await tester.tap(find.byKey(const ValueKey('manual:abc')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.trash));
    await tester.pumpAndSettle();

    expect(find.text('Remove from Device'), findsOneWidget);
    expect(find.text('Delete Photo'), findsOneWidget);
  });

  testWidgets(
    'deleting a photo that is not backed up yet just confirms, with no cloud-only option',
    (tester) async {
      final recordStore = FakeAssetRecordStore();
      await recordStore.upsert(
        localId: 'manual:abc',
        contentHash: 'abc',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/pending.jpg',
      );
      await pumpWithRecord(tester, recordStore);

      await tester.tap(find.byKey(const ValueKey('manual:abc')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(CupertinoIcons.trash));
      await tester.pumpAndSettle();

      expect(find.text('Remove from Device'), findsNothing);
      expect(find.text('Delete this item?'), findsOneWidget);
    },
  );

  testWidgets(
    'a cloud-only photo stays in the library, drawn from its cached thumbnail',
    (tester) async {
      final recordStore = FakeAssetRecordStore();
      await recordStore.upsert(
        localId: 'manual:abc',
        contentHash: 'abc',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/gone.jpg',
      );
      await recordStore.updateDerivative(
        'manual:abc',
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'originals/manual_abc.jpg',
        ),
      );
      await recordStore.setThumbnailPath('manual:abc', '/tmp/thumb.jpg');
      await recordStore.setLocalDeleted('manual:abc', true);
      await pumpWithRecord(tester, recordStore);

      expect(find.byKey(const ValueKey('manual:abc')), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.cloud_fill), findsOneWidget);
      final image = tester.widget<Image>(
        find
            .descendant(
              of: find.byKey(const ValueKey('manual:abc')),
              matching: find.byType(Image),
            )
            .first,
      );
      expect((image.image as FileImage).file.path, '/tmp/thumb.jpg');
    },
  );

  testWidgets(
    'shows Utilities rows with real counts and navigates to each screen',
    (tester) async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      final recordStore = FakeAssetRecordStore();
      await recordStore.upsert(
        localId: 'manual:fav',
        contentHash: 'fav',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/fav.jpg',
      );
      await recordStore.setFavorite('manual:fav', true);

      // Tall surface so the Utilities section — now below the added
      // Collections (Albums/People/Places/Events) section — is built by the
      // lazy CustomScrollView without needing a scroll.
      await tester.binding.setSurfaceSize(const Size(400, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
            demoSeedStore: _alreadySeededStore(),
            assetRecordStore: recordStore,
            thumbnailCache: _noThumbnails(recordStore),
            syncJobStore: FakeSyncJobStore(),
            albumStore: FakeAlbumStore(),
            personStore: FakePersonStore(),
            backupTargetsStore: targetsStore,
            backupCoordinator: BackupCoordinator(
              targetsStore: targetsStore,
              recordStore: recordStore,
              s3Uploader: _UnusedS3Uploader(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Favorites'), findsOneWidget);
      expect(find.text('Hidden'), findsOneWidget);
      expect(find.text('Recently Deleted'), findsOneWidget);
      expect(find.text('Private Cloud'), findsOneWidget);

      await tester.tap(find.text('Favorites'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('manual:fav')), findsOneWidget);
    },
  );

  testWidgets(
    'returning from Cloud Backups retries whatever is still pending/failed',
    (tester) async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      await targetsStore.addS3(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'bucket',
        prefix: '',
      );
      final recordStore = FakeAssetRecordStore();
      await recordStore.upsert(
        localId: 'manual:pending',
        contentHash: 'p',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/pending.jpg',
      );

      // Wide enough that Cloud Backups' own "Cloud Buckets" row (heading +
      // "+ Add Cloud Bucket" button) doesn't overflow once a target's
      // configured.
      await tester.binding.setSurfaceSize(const Size(800, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
            demoSeedStore: _alreadySeededStore(),
            assetRecordStore: recordStore,
            thumbnailCache: _noThumbnails(recordStore),
            syncJobStore: FakeSyncJobStore(),
            albumStore: FakeAlbumStore(),
            personStore: FakePersonStore(),
            backupTargetsStore: targetsStore,
            backupCoordinator: BackupCoordinator(
              targetsStore: targetsStore,
              recordStore: recordStore,
              s3Uploader: _FakeS3Uploader(true),
              // Never touches the real filesystem — this test only cares
              // about the pending→uploaded status transition, not real
              // change-detection hashing.
              hashFile: (path) async => 'fake-hash',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Nothing backs it up automatically just by rendering — the target
      // was added to `targetsStore` directly (simulating "already
      // configured"), not through the Cloud Backups UI itself.
      expect(
        (await recordStore.getByLocalId('manual:pending'))!
            .stateOf(DerivativeKind.original)
            .status,
        UploadStatus.pending,
      );

      await tester.tap(find.text('Private Cloud'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(
        (await recordStore.getByLocalId('manual:pending'))!
            .stateOf(DerivativeKind.original)
            .status,
        UploadStatus.uploaded,
      );
    },
  );

  testWidgets(
    'a local edit since backup is re-hashed and re-uploaded on the next sync',
    (tester) async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      await targetsStore.addS3(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'bucket',
        prefix: '',
      );
      final recordStore = FakeAssetRecordStore();
      await recordStore.upsert(
        localId: 'manual:edited',
        contentHash: 'e',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/edited.jpg',
      );
      // Already backed up, but the "local file" now hashes differently —
      // simulates an edit made in Photos after the last successful backup.
      await recordStore.updateDerivative(
        'manual:edited',
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'originals/manual_edited.jpg',
          backedUpHash: 'old-hash',
        ),
      );

      await tester.binding.setSurfaceSize(const Size(800, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
            demoSeedStore: _alreadySeededStore(),
            assetRecordStore: recordStore,
            thumbnailCache: _noThumbnails(recordStore),
            syncJobStore: FakeSyncJobStore(),
            albumStore: FakeAlbumStore(),
            personStore: FakePersonStore(),
            backupTargetsStore: targetsStore,
            hashFile: (path) async => 'new-hash', // differs from "old-hash"
            backupCoordinator: BackupCoordinator(
              targetsStore: targetsStore,
              recordStore: recordStore,
              s3Uploader: _FakeS3Uploader(true),
              hashFile: (path) async => 'new-hash',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Private Cloud'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      final updated = (await recordStore.getByLocalId('manual:edited'))!
          .stateOf(DerivativeKind.original);
      expect(updated.status, UploadStatus.uploaded);
      expect(updated.backedUpHash, 'new-hash');
    },
  );

  testWidgets(
    'shows an Albums section under Collections, and opens an album on tap',
    (tester) async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      final recordStore = FakeAssetRecordStore();
      final albumStore = FakeAlbumStore();
      await recordStore.upsert(
        localId: 'manual:trip',
        contentHash: 'trip',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/trip.jpg',
      );
      await albumStore.upsert(
        id: 'demo-album-nature',
        name: 'Nature',
        isDemo: true,
      );
      await albumStore.addAssets('demo-album-nature', ['manual:trip']);
      await albumStore.upsert(
        id: 'demo-album-city',
        name: 'City',
        isDemo: true,
      );

      // Tall surface so the Collections and Albums headers — below both the
      // main grid and the album grid — are simultaneously built by the lazy
      // CustomScrollView, rather than one requiring a scroll that would
      // un-build the other.
      await tester.binding.setSurfaceSize(const Size(400, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
            demoSeedStore: _alreadySeededStore(),
            assetRecordStore: recordStore,
            thumbnailCache: _noThumbnails(recordStore),
            syncJobStore: FakeSyncJobStore(),
            albumStore: albumStore,
            personStore: FakePersonStore(),
            backupTargetsStore: targetsStore,
            backupCoordinator: BackupCoordinator(
              targetsStore: targetsStore,
              recordStore: recordStore,
              s3Uploader: _UnusedS3Uploader(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final albumsY = tester.getCenter(find.text('Albums')).dy;
      final peopleY = tester.getCenter(find.text('People')).dy;
      expect(albumsY, lessThan(peopleY));
      expect(find.text('Nature'), findsOneWidget);

      // A single horizontally-scrolling row, not a multi-row grid.
      expect(
        tester.getCenter(find.text('Nature')).dy,
        tester.getCenter(find.text('City')).dy,
      );

      await tester.tap(find.text('Nature'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('manual:trip')), findsOneWidget);
    },
  );

  testWidgets(
    'Collections lists People, Places and Events; People opens the People screen',
    (tester) async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      final recordStore = FakeAssetRecordStore();
      await recordStore.upsert(
        localId: 'manual:one',
        contentHash: 'one',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/one.jpg',
      );

      // Tall surface: People/Places/Events are full horizontal-scroll
      // subsections (header + a row of placeholder cards each), not single
      // list rows, so there's a lot of vertical content to fit.
      await tester.binding.setSurfaceSize(const Size(400, 3200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
            demoSeedStore: _alreadySeededStore(),
            assetRecordStore: recordStore,
            thumbnailCache: _noThumbnails(recordStore),
            syncJobStore: FakeSyncJobStore(),
            albumStore: FakeAlbumStore(),
            personStore: FakePersonStore(),
            backupTargetsStore: targetsStore,
            backupCoordinator: BackupCoordinator(
              targetsStore: targetsStore,
              recordStore: recordStore,
              s3Uploader: _UnusedS3Uploader(),
            ),
            aiAnalysisStore: FakeAiAnalysisStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final collectionsY = tester.getCenter(find.text('Collections')).dy;
      final peopleY = tester.getCenter(find.text('People')).dy;
      final utilitiesY = tester.getCenter(find.text('Utilities')).dy;
      expect(collectionsY, lessThan(peopleY));
      expect(peopleY, lessThan(utilitiesY));
      expect(find.text('Places'), findsOneWidget);
      expect(find.text('Events'), findsOneWidget);

      // Places and Events group by what the user has set on each photo —
      // nothing set here, so both show their own empty note. People (no
      // people configured either) shows an empty-state hint below its
      // header's own "More" button, which opens PeopleScreen.
      expect(find.text('No people yet. Tap + to add someone.'), findsOneWidget);
      expect(
        find.text('Set a place on a photo and it shows up here.'),
        findsOneWidget,
      );
      expect(
        find.text('Set an event on a photo and it shows up here.'),
        findsOneWidget,
      );

      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(find.text('No people yet. Tap + to add someone.'), findsWidgets);
    },
  );

  testWidgets(
    'People cards show each person\'s name and open their page on tap',
    (tester) async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      final recordStore = FakeAssetRecordStore();
      await recordStore.upsert(
        localId: 'manual:one',
        contentHash: 'one',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/one.jpg',
      );
      final personStore = FakePersonStore();
      await personStore.create(name: 'Mia Chen');

      await tester.binding.setSurfaceSize(const Size(400, 3200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
            demoSeedStore: _alreadySeededStore(),
            assetRecordStore: recordStore,
            thumbnailCache: _noThumbnails(recordStore),
            syncJobStore: FakeSyncJobStore(),
            albumStore: FakeAlbumStore(),
            personStore: personStore,
            backupTargetsStore: targetsStore,
            backupCoordinator: BackupCoordinator(
              targetsStore: targetsStore,
              recordStore: recordStore,
              s3Uploader: _UnusedS3Uploader(),
            ),
            aiAnalysisStore: FakeAiAnalysisStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Mia Chen'), findsOneWidget);

      await tester.tap(find.text('Mia Chen'));
      await tester.pumpAndSettle();

      expect(find.text('No photos tagged yet.'), findsOneWidget);
    },
  );
}

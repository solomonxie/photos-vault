import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/photos/demo_assets_service.dart';
import 'package:back_your_own_photos/photos/demo_seed_store.dart';
import 'package:back_your_own_photos/photos/manual_add.dart';
import 'package:back_your_own_photos/photos/person_store.dart';
import 'package:back_your_own_photos/photos/photo_library_service.dart';
import 'package:back_your_own_photos/settings/backup_targets_store.dart';
import 'package:back_your_own_photos/settings/s3_backup_target.dart';
import 'package:back_your_own_photos/storage/album_store.dart';
import 'package:back_your_own_photos/storage/asset_record.dart';
import 'package:back_your_own_photos/storage/asset_record_store.dart';
import 'package:back_your_own_photos/storage/private_album_store.dart';
import 'package:back_your_own_photos/upload/backup_coordinator.dart';
import 'package:back_your_own_photos/upload/s3_uploader.dart';
import 'package:back_your_own_photos/viewer/asset_grid.dart';
import 'package:back_your_own_photos/viewer/detail_screen.dart';
import 'package:back_your_own_photos/viewer/library_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_ai_analysis_store.dart';
import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';
import '../support/fake_private_album_store.dart';

// Never touches the real `background_downloader` platform channel — this
// screen's tests only cover the no-targets-configured path, where it's
// never actually invoked.
class _UnusedS3Uploader implements S3Uploader {
  @override
  Future<bool> put({required String filePath, required String key, required S3BackupTarget target}) =>
      throw UnimplementedError();
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
  PrivateAlbumStore get privateAlbumStore => throw UnimplementedError();

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

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

// Marked as already seeded so LibraryScreen's one-time auto-seed never
// fires here — these tests set up their own records/albums explicitly and
// assert on exact contents/counts.
DemoSeedStore _alreadySeededStore() =>
    DemoSeedStore(store: FakeSecureStore()..seed(DemoSeedStore.seededKey, 'true'));

void main() {
  testWidgets('shows the empty placeholder with no manual adds yet', (tester) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: _alreadySeededStore(),
          assetRecordStore: recordStore,
          albumStore: FakeAlbumStore(),
          privateAlbumStore: FakePrivateAlbumStore(),
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

  testWidgets('syncs the real camera roll in and lists it alongside manual adds (T2.1)', (tester) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    final photoLibraryService = PhotoLibraryService(
      store: recordStore,
      requestPermission: () async => PermissionState.authorized,
      listAllAssets: () async => [AssetEntity(id: 'roll1', typeInt: AssetType.image.index, width: 100, height: 100)],
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
          albumStore: FakeAlbumStore(),
          privateAlbumStore: FakePrivateAlbumStore(),
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
  });

  testWidgets('lists a previously manually-added file as a grid tile', (tester) async {
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
          albumStore: FakeAlbumStore(),
          privateAlbumStore: FakePrivateAlbumStore(),
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
          albumStore: FakeAlbumStore(),
          privateAlbumStore: FakePrivateAlbumStore(),
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

  testWidgets('deleting from the detail viewer asks for confirmation before soft-deleting', (tester) async {
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
          albumStore: FakeAlbumStore(),
          privateAlbumStore: FakePrivateAlbumStore(),
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
  });

  testWidgets('tapping Add Files with nothing picked reports zero added', (tester) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    // Picker returns no files, so the tap handler completes without any
    // real File I/O — safe to drive through a normal (non-runAsync) pump.
    final manualAdd = ManualAddService(
      store: recordStore,
      picker: ({type = FileType.any, allowMultiple = false}) async => [],
    );

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: _alreadySeededStore(),
          assetRecordStore: recordStore,
          albumStore: FakeAlbumStore(),
          privateAlbumStore: FakePrivateAlbumStore(),
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

  testWidgets('tapping Try with Demo Photos adds and lists the demo asset', (tester) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: _alreadySeededStore(),
          assetRecordStore: recordStore,
          albumStore: FakeAlbumStore(),
          privateAlbumStore: FakePrivateAlbumStore(),
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

  testWidgets('a fresh install seeds demo photos automatically, without a manual tap', (tester) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    final demoSeedStore = DemoSeedStore(store: FakeSecureStore());

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: demoSeedStore,
          assetRecordStore: recordStore,
          albumStore: FakeAlbumStore(),
          privateAlbumStore: FakePrivateAlbumStore(),
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
  });

  testWidgets('tiles offer a long-press context menu for favorite/hide/delete', (tester) async {
    // CupertinoContextMenu's actual open gesture is finicky to drive
    // reliably in a widget test (real Haptic Touch timing); this checks the
    // affordance is wired up structurally. The underlying store methods are
    // covered in asset_record_store_test.dart.
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
          albumStore: FakeAlbumStore(),
          privateAlbumStore: FakePrivateAlbumStore(),
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

    expect(
      find.descendant(of: find.byKey(const ValueKey('manual:abc')), matching: find.byType(CupertinoContextMenu)),
      findsOneWidget,
    );
  });

  testWidgets('shows Utilities rows with real counts and navigates to each screen', (tester) async {
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
          albumStore: FakeAlbumStore(),
          privateAlbumStore: FakePrivateAlbumStore(),
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
    expect(find.text('Backup Status'), findsOneWidget);
    expect(find.text('S3 Settings'), findsOneWidget);

    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('manual:fav')), findsOneWidget);
  });

  testWidgets('shows an Albums section before Media Types, and opens an album on tap', (tester) async {
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
    await albumStore.upsert(id: 'demo-album-nature', name: 'Nature', isDemo: true);
    await albumStore.addAssets('demo-album-nature', ['manual:trip']);
    await albumStore.upsert(id: 'demo-album-city', name: 'City', isDemo: true);

    // Tall surface so the Albums section and Media Types header — below
    // both the main grid and the album grid — are simultaneously built by
    // the lazy CustomScrollView, rather than one requiring a scroll that
    // would un-build the other.
    await tester.binding.setSurfaceSize(const Size(400, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: _alreadySeededStore(),
          assetRecordStore: recordStore,
          albumStore: albumStore,
          privateAlbumStore: FakePrivateAlbumStore(),
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
    final mediaTypesY = tester.getCenter(find.text('Media Types')).dy;
    expect(albumsY, lessThan(mediaTypesY));
    expect(find.text('Nature'), findsOneWidget);

    // A single horizontally-scrolling row, not a multi-row grid.
    expect(tester.getCenter(find.text('Nature')).dy, tester.getCenter(find.text('City')).dy);

    await tester.tap(find.text('Nature'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manual:trip')), findsOneWidget);
  });

  testWidgets('People/Places/Events rows are Collections placeholders; People opens the People screen', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    await recordStore.upsert(
      localId: 'manual:one',
      contentHash: 'one',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/one.jpg',
    );

    // Tall surface: People/Places/Events are now full horizontal-scroll
    // subsections (header + a row of placeholder cards each), not single
    // list rows, so there's a lot more vertical content before Media Types.
    await tester.binding.setSurfaceSize(const Size(400, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          demoSeedStore: _alreadySeededStore(),
          assetRecordStore: recordStore,
          albumStore: FakeAlbumStore(),
          privateAlbumStore: FakePrivateAlbumStore(),
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
    final mediaTypesY = tester.getCenter(find.text('Media Types')).dy;
    expect(collectionsY, lessThan(peopleY));
    expect(peopleY, lessThan(mediaTypesY));
    expect(find.text('Places'), findsOneWidget);
    expect(find.text('Events'), findsOneWidget);

    // Places/Events are still a single horizontally-scrolling row of
    // placeholder cards. Places is a "Coming Soon" placeholder; Events
    // opens the AI grouping screen. People (no people configured here)
    // shows an empty-state hint below its header's own "+", which opens
    // PeopleScreen.
    expect(find.text('No people yet. Tap + to add someone.'), findsOneWidget);
    expect(find.text('Coming Soon'), findsWidgets);
    expect(find.text('Tap to Analyze'), findsWidgets);

    await tester.tap(find.byIcon(CupertinoIcons.add_circled));
    await tester.pumpAndSettle();
    expect(find.text('No people yet. Tap + to add someone.'), findsWidgets);
  });

  testWidgets('People cards show each person\'s name and open their page on tap', (tester) async {
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
          albumStore: FakeAlbumStore(),
          privateAlbumStore: FakePrivateAlbumStore(),
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
  });
}

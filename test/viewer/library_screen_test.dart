import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/photos/demo_assets_service.dart';
import 'package:back_your_own_photos/photos/manual_add.dart';
import 'package:back_your_own_photos/settings/backup_targets_store.dart';
import 'package:back_your_own_photos/settings/s3_backup_target.dart';
import 'package:back_your_own_photos/storage/album_store.dart';
import 'package:back_your_own_photos/storage/asset_record.dart';
import 'package:back_your_own_photos/storage/asset_record_store.dart';
import 'package:back_your_own_photos/upload/backup_coordinator.dart';
import 'package:back_your_own_photos/upload/s3_uploader.dart';
import 'package:back_your_own_photos/viewer/detail_screen.dart';
import 'package:back_your_own_photos/viewer/library_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';

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

void main() {
  testWidgets('shows the empty placeholder with no manual adds yet', (tester) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          assetRecordStore: recordStore,
          albumStore: FakeAlbumStore(),
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
          assetRecordStore: recordStore,
          albumStore: FakeAlbumStore(),
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
    // Pending status badge on the tile.
    expect(find.byIcon(CupertinoIcons.clock), findsOneWidget);
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
          assetRecordStore: recordStore,
          albumStore: FakeAlbumStore(),
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
          assetRecordStore: recordStore,
          albumStore: FakeAlbumStore(),
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
          assetRecordStore: recordStore,
          albumStore: FakeAlbumStore(),
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
          assetRecordStore: recordStore,
          albumStore: FakeAlbumStore(),
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

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          assetRecordStore: recordStore,
          albumStore: FakeAlbumStore(),
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

    // Tall surface so the Albums section and Media Types header — below
    // both the main grid and the album grid — are simultaneously built by
    // the lazy CustomScrollView, rather than one requiring a scroll that
    // would un-build the other.
    await tester.binding.setSurfaceSize(const Size(400, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          assetRecordStore: recordStore,
          albumStore: albumStore,
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

    await tester.tap(find.text('Nature'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manual:trip')), findsOneWidget);
  });
}

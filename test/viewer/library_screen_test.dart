import 'dart:async';
import 'dart:io';

import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/manual_add.dart';
import 'package:photos_vault/photos/photo_changes.dart';
import 'package:photos_vault/photos/photo_library_change.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/upload/backup_coordinator.dart';
import 'package:photos_vault/upload/s3_uploader.dart';
import 'package:photos_vault/upload/sync_job.dart';
import 'package:photos_vault/viewer/album_screen.dart';
import 'package:photos_vault/viewer/asset_grid.dart';
import 'package:photos_vault/viewer/asset_grid_view.dart';
import 'package:photos_vault/viewer/built_in_album.dart';
import 'package:photos_vault/viewer/detail_screen.dart';
import 'package:photos_vault/viewer/library_screen.dart';
import 'package:photos_vault/viewer/search_picker_sheet.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/people_order.dart';
import 'package:photo_manager/photo_manager.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_ai_analysis_store.dart';
import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_local_vault.dart';
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

// Never decodes or writes a real image: `ensureFor` short-circuits on the
// null encode, so no widget test ever does real file I/O — which never
// completes under `testWidgets`' fake async.
ThumbnailCache _noThumbnails(AssetRecordStore store) =>
    ThumbnailCache(store: store, encode: (_) async => null);

/// Holds [listAll] open on demand, and counts the reloads' reads.
class _GatedRecordStore extends FakeAssetRecordStore {
  int reads = 0;
  Completer<void>? gate;

  @override
  Future<List<AssetRecord>> listAll() async {
    // The orphan sweep's own read, which a reload may make, isn't one.
    if (!'${StackTrace.current}'.contains('membership_sweep')) reads++;
    await gate?.future;
    return super.listAll();
  }
}

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

Future<void> _sendLifecycle(WidgetTester tester, AppLifecycleState state) =>
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/lifecycle',
      const StringCodec().encodeMessage(state.toString()),
      (_) {},
    );

/// The real service pages the camera roll newest-first; these fakes hand
/// back one page and then nothing, which is all any of these cases need.
Future<List<AssetEntity>> Function(int, int) pagedFrom(
  List<AssetEntity> entities,
) =>
    (page, size) async => page == 0 ? entities : const [];

Future<List<AssetEntity>> Function(int, int) pagedBy(
  List<AssetEntity> Function() entities,
) =>
    (page, size) async => page == 0 ? entities() : const [];

/// The camera-roll scan is the first job in the analyze queue, and the
/// queue rests between batches — so settling once only gets as far as it
/// being queued.
Future<void> _settleScan(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  _reloadCoalescing();

  testWidgets('shows the empty placeholder with no manual adds yet', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
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
        listAssetPage: pagedFrom([
          AssetEntity(
            id: 'roll1',
            typeInt: AssetType.image.index,
            width: 100,
            height: 100,
          ),
        ]),
        // Backing up a synced asset needs its file, resolved via the real
        // plugin (`AssetEntity.file`) — untouchable in a widget test. Stub it
        // out so the sync completes without ever hitting the platform channel.
        loadEntity: (_) async => null,
      );

      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
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
      await _settleScan(tester);

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

  testWidgets('home opens on Albums, with the photos above', (tester) async {
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

    final albums = tester.getRect(find.text('Albums'));
    expect(albums.top, lessThan(120));
    expect(
      tester.getRect(find.byKey(const ValueKey('manual:abc'))).bottom,
      lessThanOrEqualTo(albums.top),
    );
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

    await showPhotos(tester);
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

      await showPhotos(tester);
      await tester.tap(find.byKey(const ValueKey('manual:abc')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(DetailScreen), findsOneWidget);

      await tester.tap(find.byIcon(CupertinoIcons.info_circle));

      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const ValueKey('detailDeleteButton')),
      );

      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('detailDeleteButton')));
      await tester.pumpAndSettle();
      // A sheet at the bottom, the way Photos asks.
      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      expect(
        find.text('It will be moved to Recently Deleted.'),
        findsOneWidget,
      );

      // Cancelling leaves the item alone and the viewer open.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(DetailScreen), findsOneWidget);
      expect((await recordStore.listAll()).single.isDeleted, isFalse);

      await tester.tap(find.byIcon(CupertinoIcons.info_circle));

      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const ValueKey('detailDeleteButton')),
      );

      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('detailDeleteButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete Photo'));
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

    await tester.binding.setSurfaceSize(const Size(400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
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

    await tester.tap(find.text('Add Files'));
    await tester.pumpAndSettle();

    expect(find.text('Added 0 files, 0 backed up.'), findsOneWidget);
  });

  testWidgets('a fresh install shows an empty library and seeds nothing', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: FakeSyncJobStore(),
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
          backupTargetsStore: targetsStore,
          vault: FakeLocalVault(),
          backupCoordinator: BackupCoordinator(
            targetsStore: targetsStore,
            recordStore: recordStore,
            s3Uploader: _UnusedS3Uploader(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(await recordStore.listAll(), isEmpty);
    expect(find.text('No Photos Yet'), findsOneWidget);
  });

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

    await showPhotos(tester);
    await tester.longPress(find.byKey(const ValueKey('manual:abc')));
    await tester.pumpAndSettle();

    expect(find.text('1 Selected'), findsOneWidget);
    // Delete lives in More, away from Done.
    for (final action in ['Album', 'Add Tag', 'More']) {
      expect(find.text(action), findsOneWidget);
    }
    expect(find.text('Set Place'), findsNothing);
    expect(find.text('Delete'), findsNothing);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    for (final action in ['Set Place', 'Adjust Date', 'Delete']) {
      expect(find.text(action), findsOneWidget);
    }
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('1 Selected'), findsNothing);
  });

  testWidgets('a selection tap updates the bar, not the whole screen', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    for (final id in ['a', 'b']) {
      await recordStore.upsert(
        localId: 'manual:$id',
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/library_screen_test_$id.jpg',
      );
    }

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
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

    await showPhotos(tester);
    await tester.longPress(find.byKey(const ValueKey('manual:a')));
    await tester.pumpAndSettle();
    expect(find.text('1 Selected'), findsOneWidget);
    final grid = tester.widget(find.byType(AssetGridView));

    await tester.tap(find.byKey(const ValueKey('manual:b')));
    await tester.pump();

    expect(find.text('2 Selected'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.checkmark_circle_fill), findsNWidgets(2));
    expect(
      identical(tester.widget(find.byType(AssetGridView)), grid),
      isTrue,
      reason: 'the screen above the grid was not rebuilt',
    );
  });

  testWidgets('the selection bar fits a phone with nothing selected', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1206, 2622);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
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
    await showPhotos(tester);
    await tester.longPress(find.byKey(const ValueKey('manual:abc')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:abc')));
    await tester.pumpAndSettle();

    expect(find.text('Touch and hold a photo to select more.'), findsOneWidget);
    expect(find.text('Select All'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('holding then sweeping picks up every tile on the way', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    for (final id in ['manual:one', 'manual:two', 'manual:three']) {
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

    // One unbroken gesture: hold to start selecting, then keep going.
    await showPhotos(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('manual:one'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('1 Selected'), findsOneWidget);

    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('manual:two'))),
    );
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('manual:three'))),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('3 Selected'), findsOneWidget);
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

    await showPhotos(tester);
    await tester.longPress(find.byKey(const ValueKey('manual:one')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:two')));
    await tester.pumpAndSettle();
    expect(find.text('2 Selected'), findsOneWidget);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set Place'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(searchPickerFieldKey), 'Kyoto');
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
    await recordStore.updateDerivative(
      'manual:abc',
      DerivativeKind.thumbnail,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'thumbnails/manual_abc.jpg',
      ),
    );
    await pumpWithRecord(tester, recordStore);

    await showPhotos(tester);
    await tester.tap(find.byKey(const ValueKey('manual:abc')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.info_circle));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('detailDeleteButton')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('detailDeleteButton')));
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

      await showPhotos(tester);
      await tester.tap(find.byKey(const ValueKey('manual:abc')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(CupertinoIcons.info_circle));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('detailDeleteButton')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('detailDeleteButton')));
      await tester.pumpAndSettle();

      expect(find.text('Remove from Device'), findsNothing);
      expect(
        find.text('It will be moved to Recently Deleted.'),
        findsOneWidget,
      );
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

  group('the two built-in album cards', () {
    // Scoped: the grid tile under these cards draws a heart of its own on
    // a favourite, which is not the card's cover.
    Finder coverIcon(IconData icon) => find.descendant(
      of: find.byType(BuiltInAlbumCoverArt),
      matching: find.byIcon(icon),
    );

    Future<void> pumpCollections(
      WidgetTester tester,
      FakeAssetRecordStore recordStore,
    ) async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      // Tall enough that the Albums row is built without a scroll — see
      // the Albums section test.
      await tester.binding.setSurfaceSize(const Size(400, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
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

    Future<FakeAssetRecordStore> oneFavouriteVideo() async {
      final recordStore = FakeAssetRecordStore();
      await recordStore.upsert(
        localId: 'manual:clip',
        contentHash: 'clip',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/clip.mp4',
        isVideo: true,
      );
      await recordStore.setThumbnailPath('manual:clip', '/tmp/clip-thumb.jpg');
      await recordStore.setFavorite('manual:clip', true);
      return recordStore;
    }

    testWidgets('wear their colour, not the newest photo in them', (
      tester,
    ) async {
      await pumpCollections(tester, await oneFavouriteVideo());

      expect(
        find.byType(BuiltInAlbumCoverArt),
        findsNWidgets(3),
        reason: 'every built-in card coloured, none of them the clip itself',
      );
      expect(coverIcon(CupertinoIcons.heart_fill), findsOneWidget);
      expect(coverIcon(CupertinoIcons.play_fill), findsOneWidget);
      expect(coverIcon(CupertinoIcons.clock_fill), findsOneWidget);
    });

    testWidgets('and a chosen cover wins over the colour', (tester) async {
      final recordStore = await oneFavouriteVideo();
      await setBuiltInAlbumCover(
        recordStore,
        BuiltInAlbum.videos,
        'manual:clip',
      );
      await pumpCollections(tester, recordStore);

      expect(
        find.byType(BuiltInAlbumCoverArt),
        findsNWidgets(2),
        reason: 'Favourites still coloured; Videos shows the chosen photo',
      );
      expect(coverIcon(CupertinoIcons.play_fill), findsNothing);
      expect(coverIcon(CupertinoIcons.heart_fill), findsOneWidget);
    });
  });

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
      // Collections (Albums/People/Places) section — is built by the
      // lazy CustomScrollView without needing a scroll.
      await tester.binding.setSurfaceSize(const Size(400, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
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
      // The backup queue lives on Cloud Settings, with the buckets.
      expect(find.text('Backup Queue'), findsNothing);
      // The analyze queue lives under People.
      expect(find.text('Analyze Queue'), findsNothing);
      expect(find.text('Cloud Settings'), findsOneWidget);

      await tester.tap(find.text('Favorites'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('manual:fav')), findsOneWidget);
    },
  );

  testWidgets('a pending photo backs up on its own once a bucket is set up', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    await targetsStore.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'bucket',
      prefix: '',
    );
    final recordStore = FakeAssetRecordStore();
    // A file that's really there: the queue skips a photo whose path
    // resolves to nothing, so a fake path would test the skip rather
    // than the retry. Made synchronously — an awaited file operation
    // inside `testWidgets` waits on a clock the test controls, and never
    // comes back.
    final dir = Directory.systemTemp.createTempSync('pending');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/pending.jpg')..writeAsBytesSync([1, 2, 3]);
    await recordStore.upsert(
      localId: 'manual:pending',
      contentHash: 'p',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: file.path,
    );

    // Wide enough that Cloud Backups' own "Cloud Buckets" row (heading +
    // "+ Add Cloud Bucket" button) doesn't overflow once a target's
    // configured.
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: FakeSyncJobStore(),
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
          backupTargetsStore: targetsStore,
          // The screen and the coordinator have to agree on what a file
          // hashes to. Give them different answers and every check for
          // local changes finds one, flips the record back to pending,
          // re-uploads, and finds one again — forever.
          hashFile: (path) async => 'fake-hash',
          backupCoordinator: BackupCoordinator(
            targetsStore: targetsStore,
            recordStore: recordStore,
            s3Uploader: _FakeS3Uploader(true),
            hashFile: (path) async => 'fake-hash',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Backup is always automatic: a configured bucket and a pending
    // photo is all it takes.
    expect(
      (await recordStore.getByLocalId('manual:pending'))!
          .stateOf(DerivativeKind.original)
          .status,
      UploadStatus.uploaded,
    );
  });

  testWidgets(
    'a local edit since backup is re-hashed and re-uploaded on the next sync',
    (tester) async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      await targetsStore.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'bucket',
        prefix: '',
      );
      final recordStore = FakeAssetRecordStore();
      // A real file, made synchronously — see the note in the test above.
      final dir = Directory.systemTemp.createTempSync('edited');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/edited.jpg')..writeAsBytesSync([1, 2, 3]);
      await recordStore.upsert(
        localId: 'manual:edited',
        contentHash: 'e',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: file.path,
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

      await tester.tap(find.text('Cloud Settings'));
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
      await albumStore.upsert(id: 'album-nature', name: 'Nature');
      await albumStore.addAssets('album-nature', ['manual:trip']);
      await albumStore.upsert(id: 'album-city', name: 'City');

      // Tall surface so the Collections and Albums headers — below both the
      // main grid and the album grid — are simultaneously built by the lazy
      // CustomScrollView, rather than one requiring a scroll that would
      // un-build the other.
      await tester.binding.setSurfaceSize(const Size(400, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
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
      // Past Favourites, Videos, Recently Added and Archive on the same row.
      await tester.dragUntilVisible(
        find.text('Nature'),
        find
            .ancestor(of: find.text('Videos'), matching: find.byType(ListView))
            .first,
        const Offset(-150, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nature'), findsOneWidget);

      // A single horizontally-scrolling row, not a multi-row grid. The
      // built-in Favourites and Videos cards come first, so the user's own
      // albums are further along it.
      expect(
        tester.getCenter(find.text('Nature')).dy,
        tester.getCenter(find.text('Archive')).dy,
      );

      await tester.tap(find.text('Nature'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('manual:trip')), findsOneWidget);
    },
  );

  testWidgets('home People row follows the People sort', (tester) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    for (final (id, at) in [
      ('manual:old', DateTime(2001)),
      ('manual:new', DateTime(2024)),
    ]) {
      await recordStore.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/$id.jpg',
        createdAt: at,
        addedAt: DateTime(2026),
      );
    }
    final personStore = FakePersonStore();
    final amy = await personStore.create(name: 'Amy');
    final zed = await personStore.create(name: 'Zed');
    await personStore.addAssets(amy.id, ['manual:old']);
    await personStore.addAssets(zed.id, ['manual:new']);
    await tester.binding.setSurfaceSize(const Size(400, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> pump() async {
      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
            key: UniqueKey(),
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
    }

    double x(String name) => tester.getCenter(find.text(name).first).dx;

    // Default: last seen, most recent first.
    await pump();
    expect(x('Zed'), lessThan(x('Amy')));

    await recordStore.setAppState(peopleSortKey, PeopleSort.name.name);
    await pump();
    expect(x('Amy'), lessThan(x('Zed')));
  });

  testWidgets('People and Places each get a section; People opens its screen', (
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

    // Tall surface: People is a full horizontal-scroll subsection and
    // Places is a list under its own header, so there's a lot of
    // vertical content to fit.
    await tester.binding.setSurfaceSize(const Size(400, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
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

    // Albums, People and Places are sections in their own right now —
    // there's no "Collections" heading above them to look for.
    final albumsY = tester.getCenter(find.text('Albums')).dy;
    final peopleY = tester.getCenter(find.text('People')).dy;
    final utilitiesY = tester.getCenter(find.text('More')).dy;
    expect(albumsY, lessThan(peopleY));
    expect(peopleY, lessThan(utilitiesY));
    expect(find.text('Places'), findsOneWidget);

    // Places groups by what the user has set on each photo — nothing set
    // here, so it shows its empty note. People (no people configured
    // either) shows an empty-state hint below its header's own "More"
    // button, which opens PeopleScreen.
    expect(find.text('No people yet. Tap + to add someone.'), findsOneWidget);
    expect(
      find.text('Photos with a place set will show up here.'),
      findsOneWidget,
    );

    // The section headers' browse-all button. It used to say "More",
    // which now names the section holding the app's own tools.
    await tester.tap(find.text('See All').first);
    await tester.pumpAndSettle();
    expect(find.text('No people yet. Tap + to add someone.'), findsWidgets);
  });

  testWidgets('Albums always shows, with Videos in it and a way to make one', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    await recordStore.upsert(
      localId: 'manual:clip',
      contentHash: 'clip',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/clip.mp4',
      isVideo: true,
    );
    final albumStore = FakeAlbumStore();

    await tester.binding.setSurfaceSize(const Size(400, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
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
          aiAnalysisStore: FakeAiAnalysisStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // With no albums of the user's own, the section is still there — it has
    // the one the library makes for itself.
    expect(find.text('Albums'), findsOneWidget);
    expect(find.text('Videos'), findsOneWidget);

    // Albums come before People.
    expect(
      tester.getCenter(find.text('Albums')).dy,
      lessThan(tester.getCenter(find.text('People')).dy),
    );

    await tester.tap(
      find.descendant(
        of: find
            .ancestor(of: find.text('Albums'), matching: find.byType(Row))
            .first,
        matching: find.byIcon(CupertinoIcons.add_circled),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoTextField).last, 'Japan');
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect((await albumStore.listAll()).single.name, 'Japan');
    // Straight into the new album: the next question is what goes in it.
    expect(find.byType(AlbumScreen), findsOneWidget);
  });

  testWidgets('Places reads as a list, folding the long tail behind Show All', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    const places = ['Kyoto', 'Osaka', 'Nara', 'Tokyo', 'Hakone', 'Nikko'];
    for (final (i, place) in places.indexed) {
      await recordStore.upsert(
        localId: 'manual:$place',
        contentHash: place,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/$place.jpg',
        // Equal sizes go by their oldest photo.
        createdAt: DateTime(2020).add(Duration(days: i)),
      );
      await recordStore.setLocation('manual:$place', place);
    }

    await tester.binding.setSurfaceSize(const Size(400, 3200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
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

    // Five of the six, then the way to the rest.
    expect(find.text('Kyoto'), findsOneWidget);
    expect(find.text('Nikko'), findsNothing);
    await tester.tap(find.text('Show All (6)'));
    await tester.pumpAndSettle();
    expect(find.text('Nikko'), findsOneWidget);
  });

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

  testWidgets('a new photo hidden once on screen is not queued for backup', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    await targetsStore.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'bucket',
      prefix: '',
    );
    final recordStore = _HidesOnceDrawn('photo:roll1');
    final jobs = _RecordingSyncJobStore();
    final photoLibraryService = PhotoLibraryService(
      store: recordStore,
      requestPermission: () async => PermissionState.authorized,
      listAssetPage: pagedFrom([
        AssetEntity(
          id: 'roll1',
          typeInt: AssetType.image.index,
          width: 100,
          height: 100,
        ),
      ]),
      loadEntity: (_) async => null,
    );
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: jobs,
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
    await _settleScan(tester);

    expect(recordStore.hid, isTrue);
    expect(jobs.queued, isNot(contains('photo:roll1')));
  });

  testWidgets(
    'coming back to the app re-reads what changed in Photos while away',
    (tester) async {
      final targetsStore = BackupTargetsStore(store: FakeSecureStore());
      final recordStore = FakeAssetRecordStore();
      var favouritedInPhotos = true;
      var scans = 0;
      final photoLibraryService = PhotoLibraryService(
        store: recordStore,
        requestPermission: () async => PermissionState.authorized,
        listAssetPage: pagedBy(() {
          scans++;
          return [
            AssetEntity(
              id: 'roll1',
              typeInt: AssetType.image.index,
              width: 100,
              height: 100,
              isFavorite: favouritedInPhotos,
            ),
          ];
        }),
        loadEntity: (_) async => null,
      );

      await tester.pumpWidget(
        _wrap(
          LibraryScreen(
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
      await _settleScan(tester);
      // Opening reads the newest pages on the head lane and then the whole
      // roll on the backstop, so more than one listing here is the point.
      expect(scans, greaterThan(0));
      final atLaunch = scans;
      expect(
        (await recordStore.getByLocalId('photo:roll1'))!.isFavorite,
        isTrue,
      );

      // Off to Photos, un-heart it, and back — driven through the real
      // lifecycle channel, so this covers the wiring and not just the
      // method.
      favouritedInPhotos = false;
      await _sendLifecycle(tester, AppLifecycleState.inactive);
      await _sendLifecycle(tester, AppLifecycleState.resumed);
      await _settleScan(tester);

      expect(scans, greaterThan(atLaunch));
      expect(
        (await recordStore.getByLocalId('photo:roll1'))!.isFavorite,
        isFalse,
      );
    },
  );

  testWidgets('a resume reads the change history, not the whole roll', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    final changes = _ScriptedChanges();
    var listings = 0;
    final photoLibraryService = PhotoLibraryService(
      store: recordStore,
      requestPermission: () async => PermissionState.authorized,
      listAssetPage: pagedBy(() {
        listings++;
        return [
          AssetEntity(
            id: 'roll1',
            typeInt: AssetType.image.index,
            width: 100,
            height: 100,
          ),
        ];
      }),
      loadEntity: (_) async => null,
      changes: changes,
    );

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
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
    await _settleScan(tester);
    expect(
      await recordStore.getAppState(PhotoLibraryService.changeTokenKey),
      't0',
      reason: 'no token at first launch: the full pass ran and left one',
    );
    final atLaunch = listings;

    changes.next = const PhotoChangeDelta(
      change: PhotoLibraryChange(updated: {'roll1'}),
      token: 't1',
    );
    await _sendLifecycle(tester, AppLifecycleState.inactive);
    await _sendLifecycle(tester, AppLifecycleState.resumed);
    await _settleScan(tester);

    expect(changes.asked, ['t0']);
    expect(listings, atLaunch + 1, reason: 'the recent lane, and no more');
    expect(
      await recordStore.getAppState(PhotoLibraryService.changeTokenKey),
      't1',
    );
  });

  testWidgets('selection mode deletes the whole selection, once confirmed', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    for (final id in ['one', 'two', 'three']) {
      await recordStore.upsert(
        localId: 'manual:$id',
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/$id.jpg',
      );
    }

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
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

    await showPhotos(tester);
    await tester.longPress(find.byKey(const ValueKey('manual:one')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:two')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Named, because by now the selection has usually scrolled out of view.
    await tester.tap(
      find.widgetWithText(CupertinoActionSheetAction, 'Delete 2 Photos'),
    );
    await tester.pumpAndSettle();

    expect((await recordStore.getByLocalId('manual:one'))!.isDeleted, isTrue);
    expect((await recordStore.getByLocalId('manual:two'))!.isDeleted, isTrue);
    expect(
      (await recordStore.getByLocalId('manual:three'))!.isDeleted,
      isFalse,
    );
    // …and selection mode is over, since what was selected is gone.
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('and leaves them alone when the confirmation is declined', (
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

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
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

    await showPhotos(tester);
    await tester.longPress(find.byKey(const ValueKey('manual:one')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect((await recordStore.getByLocalId('manual:one'))!.isDeleted, isFalse);
  });

  testWidgets('a hidden photo is not uploaded while its album is locked, '
      'and its neighbours still are', (tester) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    await targetsStore.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'bucket',
      prefix: '',
    );
    final recordStore = FakeAssetRecordStore();
    // Real files, made synchronously — see the note in the tests above.
    final dir = Directory.systemTemp.createTempSync('private-sync');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final name in ['secret', 'ordinary']) {
      File('${dir.path}/$name.jpg').writeAsBytesSync([1, 2, 3]);
      await recordStore.upsert(
        localId: 'manual:$name',
        contentHash: name,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '${dir.path}/$name.jpg',
      );
    }
    final hash = hashPasscode('1234');
    await recordStore.setPasscodeHash('manual:secret', hash);

    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: FakeSyncJobStore(),
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
          backupTargetsStore: targetsStore,
          hashFile: (path) async => 'fake-hash',
          backupCoordinator: BackupCoordinator(
            targetsStore: targetsStore,
            recordStore: recordStore,
            s3Uploader: _FakeS3Uploader(true),
            hashFile: (path) async => 'fake-hash',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Coming back from Cloud Settings syncs everything still owed.
    await tester.tap(find.text('Cloud Settings'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(
      (await recordStore.getByLocalId('manual:ordinary'))!
          .stateOf(DerivativeKind.original)
          .status,
      UploadStatus.uploaded,
    );
    // Hidden, and no album key in the ring — this coordinator has no vault
    // at all — so it is held rather than sent up in the clear. Still
    // `pending`, deliberately: `failed` would read as something to fix.
    expect(
      (await recordStore.getByLocalId('manual:secret'))!
          .stateOf(DerivativeKind.original)
          .status,
      UploadStatus.pending,
    );
  });

  testWidgets('Remove All App Data sits at the foot of the home page', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();

    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: FakeSyncJobStore(),
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
          aiAnalysisStore: FakeAiAnalysisStore(),
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

    // Last on the page, under the note that explains what there is to lose.
    // It used to be filed in Cloud Settings, which is a page about where
    // photos go rather than about the whole app.
    final privacyY = tester
        .getCenter(find.text('Your Copies, Your Privacy'))
        .dy;
    final removeY = tester.getCenter(find.text('Remove All App Data')).dy;
    expect(privacyY, lessThan(removeY));

    await tester.tap(find.text('Remove All App Data'));
    await tester.pumpAndSettle();

    expect(find.text('Remove all app data?'), findsOneWidget);
    // No prompt and no share sheet: the dialog's job is to say that a copy
    // is taken anyway, and to name it well enough to find afterwards.
    expect(find.textContaining('pre-deletion'), findsOneWidget);
  });
}

/// Home opens on Albums, below the grid: up to the photos.
Future<void> showPhotos(WidgetTester tester) async {
  tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .jumpTo(0);
  await tester.pump();
}

/// Hides [localId] at the first reload that would draw it — the user
/// hiding a new photo before its backup is queued.
class _HidesOnceDrawn extends FakeAssetRecordStore {
  _HidesOnceDrawn(this.localId);

  final String localId;
  bool hid = false;

  @override
  Future<List<AssetRecord>> listAll() async {
    if (!hid && await getByLocalId(localId) != null) {
      hid = true;
      await setPasscodeHash(localId, hashPasscode('1234'));
    }
    return super.listAll();
  }
}

class _RecordingSyncJobStore extends FakeSyncJobStore {
  final queued = <String>{};

  @override
  Future<SyncJob> enqueue({
    required String localId,
    required SyncJobKind kind,
    required String displayName,
    required DateTime assetCreatedAt,
    int priority = 0,
  }) {
    queued.add(localId);
    return super.enqueue(
      localId: localId,
      kind: kind,
      displayName: displayName,
      assetCreatedAt: assetCreatedAt,
      priority: priority,
    );
  }
}

void _reloadCoalescing() {
  testWidgets('the newest photos are up before the first full read is in', (
    tester,
  ) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = _GatedRecordStore()..gate = Completer<void>();
    await recordStore.upsert(
      localId: 'manual:new',
      contentHash: 'new',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/new.jpg',
    );
    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
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
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('manual:new')), findsOneWidget);

    recordStore.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('manual:new')), findsOneWidget);
  });

  testWidgets('launch work waits for the screen to go quiet', (tester) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    var listed = 0;
    final photoLibraryService = PhotoLibraryService(
      store: recordStore,
      requestPermission: () async => PermissionState.authorized,
      listAssetPage: (page, size) async {
        listed++;
        return const [];
      },
      loadEntity: (_) async => null,
    );
    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
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
          launchSettle: const Duration(seconds: 4),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(listed, 1, reason: 'the recent lane, at once');

    // Second stage due at 8 s; a touch at 6 s puts it back to 12 s.
    await tester.pump(const Duration(seconds: 6));
    final touch = await tester.startGesture(const Offset(5, 5));
    await touch.up();
    await tester.pump(const Duration(seconds: 3));
    expect(listed, 1, reason: 'not while somebody is using it');

    await tester.pump(const Duration(seconds: 3));
    expect(listed, 2, reason: 'then the full pass');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reloads run one at a time; callers meanwhile share one more, '
      'which sees what they wrote', (tester) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = _GatedRecordStore();
    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
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
    final state = tester.state<LibraryScreenState>(find.byType(LibraryScreen));

    recordStore.gate = Completer<void>();
    final before = recordStore.reads;
    final first = state.reload();
    await tester.pump();
    await recordStore.upsert(
      localId: 'manual:late',
      contentHash: 'late',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/late.jpg',
    );
    final second = state.reload();
    final third = state.reload(faces: true);
    expect(identical(second, third), isTrue);
    expect(identical(first, second), isFalse);

    recordStore.gate!.complete();
    recordStore.gate = null;
    await tester.pumpAndSettle();
    await first;
    await third;

    expect(recordStore.reads - before, 2);
    expect(find.byType(AssetTile), findsOneWidget);
  });

  testWidgets('a reload re-reads albums only after they were written, and '
      'the card still follows a heart', (tester) async {
    final targetsStore = BackupTargetsStore(store: FakeSecureStore());
    final recordStore = FakeAssetRecordStore();
    for (final id in ['manual:a', 'manual:b']) {
      await recordStore.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/$id.jpg',
      );
    }
    final albums = _StampedAlbums();
    await albums.upsert(id: 'trip', name: 'Trip');
    await albums.addAssets('trip', ['manual:a']);
    await tester.pumpWidget(
      _wrap(
        LibraryScreen(
          assetRecordStore: recordStore,
          thumbnailCache: _noThumbnails(recordStore),
          syncJobStore: FakeSyncJobStore(),
          albumStore: albums,
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
    final state = tester.state<LibraryScreenState>(find.byType(LibraryScreen));
    final reads = albums.memberReads;

    await recordStore.setFavorite('manual:a', true);
    await state.reload();
    await tester.pumpAndSettle();
    expect(albums.memberReads, reads);

    await albums.addAssets('trip', ['manual:b']);
    await state.reload();
    await tester.pumpAndSettle();
    expect(albums.memberReads, reads + 1);
    expect(find.text('2', skipOffstage: false), findsWidgets);
  });
}

/// Stamps like the real store: equal until something is written.
class _StampedAlbums extends FakeAlbumStore {
  var writes = 0;
  var memberReads = 0;

  @override
  Future<Object> changeStamp() async => writes;

  @override
  Future<void> addAssets(String albumId, Iterable<String> localIds) {
    writes++;
    return super.addAssets(albumId, localIds);
  }

  @override
  Future<Map<String, List<String>>> allMemberships() {
    memberReads++;
    return super.allMemberships();
  }
}

class _ScriptedChanges extends PhotoChanges {
  PhotoChangeDelta? next;
  final asked = <String>[];

  @override
  Future<String?> token() async => 't0';

  @override
  Future<PhotoChangeDelta?> since(String token) async {
    asked.add(token);
    return next;
  }
}

import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/storage/album.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/album_screen.dart';
import 'package:photos_vault/viewer/search_picker_sheet.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  final album = Album(id: 'a1', name: 'Nature', createdAt: DateTime(2024));

  testWidgets('shows only this album\'s members, excluding hidden/deleted', (
    tester,
  ) async {
    final recordStore = FakeAssetRecordStore();
    final albumStore = FakeAlbumStore();
    await recordStore.upsert(
      localId: 'manual:in',
      contentHash: 'in',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/in.jpg',
    );
    await recordStore.upsert(
      localId: 'manual:not-in',
      contentHash: 'ni',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/ni.jpg',
    );
    await recordStore.upsert(
      localId: 'manual:hidden',
      contentHash: 'h',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/h.jpg',
    );
    await recordStore.setHidden('manual:hidden', true);
    await albumStore.addAssets('a1', ['manual:in', 'manual:hidden']);

    await tester.pumpWidget(
      _wrap(
        AlbumScreen(
          album: album,
          assetRecordStore: recordStore,
          albumStore: albumStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manual:in')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual:not-in')), findsNothing);
    expect(find.byKey(const ValueKey('manual:hidden')), findsNothing);
  });

  testWidgets('shows the empty state with no members', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AlbumScreen(
          album: album,
          assetRecordStore: FakeAssetRecordStore(),
          albumStore: FakeAlbumStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No photos in this album.'), findsOneWidget);
  });

  testWidgets('Remove from Album drops membership without deleting the asset', (
    tester,
  ) async {
    final recordStore = FakeAssetRecordStore();
    final albumStore = FakeAlbumStore();
    await recordStore.upsert(
      localId: 'manual:in',
      contentHash: 'in',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/in.jpg',
    );
    await albumStore.addAssets('a1', ['manual:in']);

    await tester.pumpWidget(
      _wrap(
        AlbumScreen(
          album: album,
          assetRecordStore: recordStore,
          albumStore: albumStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await albumStore.removeAsset('a1', 'manual:in');
    expect(await albumStore.localIdsIn('a1'), isEmpty);
    expect(await recordStore.getByLocalId('manual:in'), isNotNull);
  });

  testWidgets('select several, then remove them from the album only', (
    tester,
  ) async {
    final recordStore = FakeAssetRecordStore();
    final albumStore = FakeAlbumStore();
    for (final id in ['a', 'b', 'c']) {
      await recordStore.upsert(
        localId: 'manual:$id',
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/$id.jpg',
      );
    }
    await albumStore.addAssets('a1', ['manual:a', 'manual:b', 'manual:c']);

    await tester.pumpWidget(
      _wrap(
        AlbumScreen(
          album: album,
          assetRecordStore: recordStore,
          albumStore: albumStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('albumSelect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:a')));
    await tester.tap(find.byKey(const ValueKey('manual:c')));
    await tester.pump();
    expect(find.text('2 Selected'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('albumRemoveSelected')));
    await tester.pumpAndSettle();

    expect(await albumStore.localIdsIn('a1'), ['manual:b']);
    expect(await recordStore.getByLocalId('manual:a'), isNotNull);
    expect(find.byKey(const ValueKey('manual:a')), findsNothing);
    expect(find.byKey(const ValueKey('albumRemoveSelected')), findsNothing);
  });

  testWidgets('More: archive or delete what is selected', (tester) async {
    final recordStore = FakeAssetRecordStore();
    final albumStore = FakeAlbumStore();
    for (final id in ['a', 'b']) {
      await recordStore.upsert(
        localId: 'manual:$id',
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/$id.jpg',
      );
    }
    await albumStore.addAssets('a1', ['manual:a', 'manual:b']);
    await tester.pumpWidget(
      _wrap(
        AlbumScreen(
          album: album,
          assetRecordStore: recordStore,
          albumStore: albumStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> pickThen(String id, String action) async {
      await tester.tap(find.byKey(const ValueKey('albumSelect')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(id)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('albumSelectionMore')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(action)));
      await tester.pumpAndSettle();
    }

    await pickThen('manual:a', 'albumArchiveSelected');
    expect((await recordStore.getByLocalId('manual:a'))!.isArchived, isTrue);
    expect(await albumStore.localIdsIn('a1'), contains('manual:a'));

    await pickThen('manual:b', 'albumDeleteSelected');
    await tester.tap(find.text('Delete 1 Photo'));
    await tester.pumpAndSettle();
    expect((await recordStore.getByLocalId('manual:b'))!.isDeleted, isTrue);
    expect(find.byKey(const ValueKey('manual:b')), findsNothing);
  });

  testWidgets('an album carries its own note and tags', (tester) async {
    final recordStore = FakeAssetRecordStore();
    final albumStore = FakeAlbumStore();
    await albumStore.upsert(id: 'a1', name: 'Nature');

    await tester.pumpWidget(
      _wrap(
        AlbumScreen(
          album: album,
          assetRecordStore: recordStore,
          albumStore: albumStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(CupertinoTextField), 'Kyoto, October');
    await tester.pump();

    // The note is about the set, not about any one photo in it.
    expect((await albumStore.getById('a1'))!.description, 'Kyoto, October');

    await tester.tap(find.text('Tags'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(searchPickerFieldKey), 'trip');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use "trip"'));
    await tester.pumpAndSettle();

    expect((await albumStore.getById('a1'))!.tags, ['trip']);
    expect(find.text('trip'), findsOneWidget);
  });

  testWidgets('photos are added from the library, not imported again', (
    tester,
  ) async {
    final recordStore = FakeAssetRecordStore();
    final albumStore = FakeAlbumStore();
    await albumStore.upsert(id: 'a1', name: 'Nature');
    await recordStore.upsert(
      localId: 'manual:free',
      contentHash: 'free',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/free.jpg',
    );

    await tester.pumpWidget(
      _wrap(
        AlbumScreen(
          album: album,
          assetRecordStore: recordStore,
          albumStore: albumStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The nav bar's own +, not the "add a tag" one in the header.
    await tester.tap(
      find.descendant(
        of: find.byType(CupertinoNavigationBar),
        matching: find.byIcon(CupertinoIcons.add),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:free')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add 1'));
    await tester.pumpAndSettle();

    expect(await albumStore.localIdsIn('a1'), ['manual:free']);
  });

  testWidgets('notes show below the photos, and with none', (tester) async {
    final recordStore = FakeAssetRecordStore();
    final albumStore = FakeAlbumStore();
    await recordStore.upsert(
      localId: 'manual:in',
      contentHash: 'in',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/in.jpg',
    );
    await albumStore.addAssets('a1', ['manual:in']);
    await albumStore.noteBook('a1').save('See https://example.com');

    await tester.pumpWidget(
      _wrap(
        AlbumScreen(
          album: album,
          assetRecordStore: recordStore,
          albumStore: albumStore,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('hiddenNoteAdd')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const ValueKey('hiddenNoteAdd')), findsOneWidget);
    expect(
      find.textContaining('example.com', findRichText: true),
      findsOneWidget,
    );
  });
}

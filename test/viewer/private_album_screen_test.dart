import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/storage/asset_record.dart';
import 'package:back_your_own_photos/viewer/private_album_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_private_album_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  testWidgets('shows only this album\'s members', (tester) async {
    final assetStore = FakeAssetRecordStore();
    final albumStore = FakePrivateAlbumStore();
    await assetStore.upsert(
      localId: 'manual:in',
      contentHash: 'in',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/in.jpg',
    );
    await assetStore.upsert(
      localId: 'manual:out',
      contentHash: 'out',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/out.jpg',
    );
    final album = await albumStore.ensure('1234');
    await albumStore.addAssets(album.id, ['manual:in'], moved: true);

    await tester.pumpWidget(
      _wrap(PrivateAlbumScreen(album: album, assetRecordStore: assetStore, privateAlbumStore: albumStore)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manual:in')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual:out')), findsNothing);
  });

  testWidgets('shows the empty state for a never-persisted album', (tester) async {
    final assetStore = FakeAssetRecordStore();
    final albumStore = FakePrivateAlbumStore();
    final album = await albumStore.ensure('1234');
    await albumStore.remove(album.id); // simulate an ephemeral, not-yet-persisted album

    await tester.pumpWidget(
      _wrap(PrivateAlbumScreen(album: album, assetRecordStore: assetStore, privateAlbumStore: albumStore)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing here yet.'), findsOneWidget);
  });

  testWidgets('shows the item count and offers a long-press context menu', (tester) async {
    // CupertinoContextMenu's open gesture is finicky to drive reliably in a
    // widget test (real Haptic Touch timing) — same convention as
    // library_screen_test.dart's equivalent check. `_removeFromAlbum`'s
    // actual store effects are exercised via PrivateAlbumStore directly in
    // private_album_store_test.dart / fake_private_album_store.dart.
    final assetStore = FakeAssetRecordStore();
    final albumStore = FakePrivateAlbumStore();
    await assetStore.upsert(
      localId: 'manual:in',
      contentHash: 'in',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/in.jpg',
    );
    final album = await albumStore.ensure('1234');
    await albumStore.addAssets(album.id, ['manual:in'], moved: true);

    await tester.pumpWidget(
      _wrap(PrivateAlbumScreen(album: album, assetRecordStore: assetStore, privateAlbumStore: albumStore)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('1 item'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey('manual:in')), matching: find.byType(CupertinoContextMenu)),
      findsOneWidget,
    );
  });

  testWidgets('multi-select "Move to Library" un-hides moved assets and clears the album', (tester) async {
    final assetStore = FakeAssetRecordStore();
    final albumStore = FakePrivateAlbumStore();
    await assetStore.upsert(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/a.jpg',
    );
    await assetStore.upsert(
      localId: 'manual:b',
      contentHash: 'b',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/b.jpg',
    );
    await assetStore.setHidden('manual:a', true);
    await assetStore.setHidden('manual:b', true);
    final album = await albumStore.ensure('1234');
    await albumStore.addAssets(album.id, ['manual:a', 'manual:b'], moved: true);

    await tester.pumpWidget(
      _wrap(PrivateAlbumScreen(album: album, assetRecordStore: assetStore, privateAlbumStore: albumStore)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:a')));
    await tester.tap(find.byKey(const ValueKey('manual:b')));
    await tester.pump();

    await tester.tap(find.text('Move 2 to Library'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing here yet.'), findsOneWidget);
    expect((await assetStore.getByLocalId('manual:a'))!.isHidden, isFalse);
    expect((await assetStore.getByLocalId('manual:b'))!.isHidden, isFalse);
    expect(await albumStore.localIdsIn(album.id), isEmpty);
  });

  testWidgets('Cancel during select mode discards the selection', (tester) async {
    final assetStore = FakeAssetRecordStore();
    final albumStore = FakePrivateAlbumStore();
    await assetStore.upsert(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/a.jpg',
    );
    final album = await albumStore.ensure('1234');
    await albumStore.addAssets(album.id, ['manual:a'], moved: true);

    await tester.pumpWidget(
      _wrap(PrivateAlbumScreen(album: album, assetRecordStore: assetStore, privateAlbumStore: albumStore)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:a')));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Select'), findsOneWidget);
    expect(await albumStore.localIdsIn(album.id), ['manual:a']);
  });
}

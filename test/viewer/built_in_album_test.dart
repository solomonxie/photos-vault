import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/viewer/built_in_album.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  test('no cover chosen means the coloured default', () async {
    final store = FakeAssetRecordStore();
    for (final album in BuiltInAlbum.values) {
      expect(await builtInAlbumCover(store, album), isNull);
    }
  });

  test('a chosen cover survives, per album', () async {
    final store = FakeAssetRecordStore();
    await setBuiltInAlbumCover(store, BuiltInAlbum.favorites, 'photo:a');

    expect(await builtInAlbumCover(store, BuiltInAlbum.favorites), 'photo:a');
    expect(
      await builtInAlbumCover(store, BuiltInAlbum.videos),
      isNull,
      reason: 'the two cards choose separately',
    );
  });

  test('and the colour can be put back', () async {
    final store = FakeAssetRecordStore();
    await setBuiltInAlbumCover(store, BuiltInAlbum.videos, 'photo:v');
    await setBuiltInAlbumCover(store, BuiltInAlbum.videos, null);

    expect(await builtInAlbumCover(store, BuiltInAlbum.videos), isNull);
  });

  testWidgets('the default draws the album\'s own symbol on its gradient', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CupertinoApp(
        home: SizedBox(
          width: 140,
          height: 140,
          child: BuiltInAlbumCoverArt(BuiltInAlbum.favorites),
        ),
      ),
    );

    expect(find.byIcon(CupertinoIcons.heart_fill), findsOneWidget);
    final box = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(BuiltInAlbumCoverArt),
        matching: find.byType(DecoratedBox),
      ),
    );
    final gradient =
        (box.decoration as BoxDecoration).gradient! as LinearGradient;
    expect(gradient.colors, [
      BuiltInAlbum.favorites.from,
      BuiltInAlbum.favorites.to,
    ]);
  });

  testWidgets('the cover actions offer the swap, then the way back', (
    tester,
  ) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context)!;
            return const SizedBox();
          },
        ),
      ),
    );

    List<String> labelsFor({required bool enabled, required bool isCover}) =>
        coverActions(
          l10n,
          enabled: enabled,
          isCover: isCover,
          onUse: () {},
          onDefault: () {},
        ).map((a) => a.label).toList();

    expect(
      labelsFor(enabled: false, isCover: false),
      isEmpty,
      reason: 'a People or Events group has no card to be the cover of',
    );
    expect(labelsFor(enabled: true, isCover: false), [l10n.albumUseAsCover]);
    expect(labelsFor(enabled: true, isCover: true), [
      l10n.albumUseDefaultCover,
    ], reason: 'on the photo that is already the cover, the way back');
  });
}

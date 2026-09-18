import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/library_custody.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/viewer/private_album_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_asset_record_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

/// Records what the album asked to be taken out of Photos, without a photo
/// library to take anything out of.
class _RecordingCustody implements LibraryCustody {
  final takenOut = <String>[];
  final returned = <String>[];

  @override
  Future<CustodyResult> takeOut(AssetRecord record) async {
    takenOut.add(record.localId);
    return CustodyResult.taken;
  }

  @override
  Future<CustodyResult> putBack(AssetRecord record) async {
    returned.add(record.localId);
    return CustodyResult.returned;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _hash = hashPasscode('1234');

void main() {
  testWidgets("shows only assets currently tagged with this passcode hash", (
    tester,
  ) async {
    final assetStore = FakeAssetRecordStore();
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
    await assetStore.setPasscodeHash('manual:in', _hash);

    await tester.pumpWidget(
      _wrap(
        PrivateAlbumScreen(passcodeHash: _hash, assetRecordStore: assetStore),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manual:in')), findsOneWidget);
    expect(find.byKey(const ValueKey('manual:out')), findsNothing);
  });

  testWidgets('shows the empty state when nothing has this passcode hash yet', (
    tester,
  ) async {
    final assetStore = FakeAssetRecordStore();

    await tester.pumpWidget(
      _wrap(
        PrivateAlbumScreen(passcodeHash: _hash, assetRecordStore: assetStore),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing here yet.'), findsOneWidget);
  });

  testWidgets('shows the item count and offers a long-press context menu', (
    tester,
  ) async {
    // CupertinoContextMenu's open gesture is finicky to drive reliably in a
    // widget test (real Haptic Touch timing) — same convention as
    // library_screen_test.dart's equivalent check.
    final assetStore = FakeAssetRecordStore();
    await assetStore.upsert(
      localId: 'manual:in',
      contentHash: 'in',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/in.jpg',
    );
    await assetStore.setPasscodeHash('manual:in', _hash);

    await tester.pumpWidget(
      _wrap(
        PrivateAlbumScreen(passcodeHash: _hash, assetRecordStore: assetStore),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('1 item'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('manual:in')),
        matching: find.byType(CupertinoContextMenu),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'multi-select "Recover to Library" clears the passcode hash on every selected asset',
    (tester) async {
      final assetStore = FakeAssetRecordStore();
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
      await assetStore.setPasscodeHash('manual:a', _hash);
      await assetStore.setPasscodeHash('manual:b', _hash);

      await tester.pumpWidget(
        _wrap(
          PrivateAlbumScreen(passcodeHash: _hash, assetRecordStore: assetStore),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('manual:a')));
      await tester.tap(find.byKey(const ValueKey('manual:b')));
      await tester.pump();

      await tester.tap(find.text('Recover 2 to Library'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing here yet.'), findsOneWidget);
      expect((await assetStore.getByLocalId('manual:a'))!.passcodeHash, isNull);
      expect((await assetStore.getByLocalId('manual:b'))!.passcodeHash, isNull);
    },
  );

  testWidgets('Cancel during select mode discards the selection', (
    tester,
  ) async {
    final assetStore = FakeAssetRecordStore();
    await assetStore.upsert(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/a.jpg',
    );
    await assetStore.setPasscodeHash('manual:a', _hash);

    await tester.pumpWidget(
      _wrap(
        PrivateAlbumScreen(passcodeHash: _hash, assetRecordStore: assetStore),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:a')));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Select'), findsOneWidget);
    expect((await assetStore.getByLocalId('manual:a'))!.passcodeHash, _hash);
  });

  testWidgets(
    'deleting the private album clears every member\'s passcode hash',
    (tester) async {
      final assetStore = FakeAssetRecordStore();
      await assetStore.upsert(
        localId: 'manual:a',
        contentHash: 'a',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/a.jpg',
      );
      await assetStore.setPasscodeHash('manual:a', _hash);

      await tester.pumpWidget(
        _wrap(
          PrivateAlbumScreen(passcodeHash: _hash, assetRecordStore: assetStore),
        ),
      );
      await tester.pumpAndSettle();

      // The page's own actions sit on the bar, not behind a "…".
      await tester.tap(find.text('Delete Private Album'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect((await assetStore.getByLocalId('manual:a'))!.passcodeHash, isNull);
    },
  );

  testWidgets('adding from the library takes the photos out of Photos too', (
    tester,
  ) async {
    final assetStore = FakeAssetRecordStore();
    await assetStore.upsert(
      localId: 'manual:free',
      contentHash: 'free',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/free.jpg',
    );
    final custody = _RecordingCustody();

    await tester.pumpWidget(
      _wrap(
        PrivateAlbumScreen(
          passcodeHash: _hash,
          assetRecordStore: assetStore,
          custody: custody,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:free')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add 1'));
    await tester.pumpAndSettle();

    // Says what it is about to do, every time — the originals leave Photos
    // and this app becomes the only holder.
    expect(find.textContaining('removed from your iPhone'), findsOneWidget);
    await tester.tap(find.text('Hide and Remove'));
    await tester.pumpAndSettle();

    // The album is already open, so its passcode isn't asked for again.
    expect((await assetStore.getByLocalId('manual:free'))!.passcodeHash, _hash);
    expect(custody.takenOut, ['manual:free'], reason: 'gone from Photos');
  });

  testWidgets('backing out of the warning hides nothing', (tester) async {
    final assetStore = FakeAssetRecordStore();
    await assetStore.upsert(
      localId: 'manual:free',
      contentHash: 'free',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/free.jpg',
    );
    final custody = _RecordingCustody();

    await tester.pumpWidget(
      _wrap(
        PrivateAlbumScreen(
          passcodeHash: _hash,
          assetRecordStore: assetStore,
          custody: custody,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:free')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(
      (await assetStore.getByLocalId('manual:free'))!.passcodeHash,
      isNull,
    );
    expect(custody.takenOut, isEmpty);
  });
}

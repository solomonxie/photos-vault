import 'dart:async';

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

  /// One call for the whole group: the OS prompts once per call, so hiding
  /// a selection must not loop.
  var takeOutCalls = 0;

  @override
  Future<Map<String, CustodyResult>> takeOutMany(
    List<AssetRecord> records,
  ) async {
    takeOutCalls++;
    for (final record in records) {
      takenOut.add(record.localId);
    }
    return {for (final r in records) r.localId: CustodyResult.taken};
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

/// Everything that acts on the album itself now lives behind the "..."
/// button, so a test that wants one of those opens it first.
Future<void> _openAlbumMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(CupertinoIcons.ellipsis_circle));
  await tester.pumpAndSettle();
}

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
      await _openAlbumMenu(tester);
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

    // Straight through: the OS puts up its own confirmation for the
    // delete, and a second dialog of ours asking the same thing is how
    // people learn to tap past both.
    expect(find.textContaining('removed from your iPhone'), findsNothing);

    // The album is already open, so its passcode isn't asked for again.
    expect((await assetStore.getByLocalId('manual:free'))!.passcodeHash, _hash);
    expect(custody.takenOut, ['manual:free'], reason: 'gone from Photos');
  });

  testWidgets('a group of photos is one trip to Photos, not one each', (
    tester,
  ) async {
    final assetStore = FakeAssetRecordStore();
    for (final name in ['one', 'two', 'three']) {
      await assetStore.upsert(
        localId: 'manual:$name',
        contentHash: name,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/$name.jpg',
      );
    }
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
    for (final name in ['one', 'two', 'three']) {
      await tester.tap(find.byKey(ValueKey('manual:$name')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Add 3'));
    await tester.pumpAndSettle();

    expect(custody.takenOut.length, 3);
    // Three photos, one system prompt. A confirmation nobody reads by the
    // third is not a confirmation.
    expect(custody.takeOutCalls, 1);
  });

  testWidgets('backgrounding the app leaves the album behind', (tester) async {
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
      _wrap(CupertinoButton(onPressed: () {}, child: const Text('library'))),
    );
    final context = tester.element(find.text('library'));
    unawaited(
      Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) => PrivateAlbumScreen(
            passcodeHash: _hash,
            assetRecordStore: assetStore,
            custody: _RecordingCustody(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PrivateAlbumScreen), findsOneWidget);

    // A control-centre swipe, a banner, or the system's own delete prompt:
    // covered, not thrown away.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.byType(PrivateAlbumScreen), findsOneWidget);

    // Actually backgrounded. (iOS goes inactive -> hidden -> paused, and
    // Flutter drops a transition that skips a step.)
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    // Nothing paints while the app is paused, so the album is gone from
    // the navigator here and gone from the screen on the way back in —
    // which is the moment that matters.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.byType(PrivateAlbumScreen), findsNothing);
    expect(find.text('library'), findsOneWidget);
  });

  testWidgets('the footer says what happens, with nothing to choose', (
    tester,
  ) async {
    final assetStore = FakeAssetRecordStore();

    await tester.pumpWidget(
      _wrap(
        PrivateAlbumScreen(
          passcodeHash: _hash,
          assetRecordStore: assetStore,
          custody: _RecordingCustody(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The footer is there on an empty album too: this is what hiding does,
    // and it is worth knowing before the first photo goes in. With no
    // bucket configured — which is this test — it says the honest thing.
    expect(find.textContaining('are not encrypted'), findsOneWidget);
    // Hiding is not finished until Photos' own Recently Deleted is empty,
    // and nothing else in the app says so.
    expect(find.textContaining('30 days'), findsOneWidget);
  });

  testWidgets('how it works opens and folds away', (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      _wrap(
        PrivateAlbumScreen(
          passcodeHash: _hash,
          assetRecordStore: FakeAssetRecordStore(),
          custody: _RecordingCustody(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A few lines to decide by, not ten unasked-for.
    expect(find.textContaining('Every code opens an album'), findsOneWidget);
    expect(find.textContaining('cannot open one'), findsNothing);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot open one'), findsOneWidget);

    await tester.tap(find.text('Less'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot open one'), findsNothing);
  });

  testWidgets('there is no backup switch left to find', (tester) async {
    final assetStore = FakeAssetRecordStore();

    await tester.pumpWidget(
      _wrap(
        PrivateAlbumScreen(
          passcodeHash: _hash,
          assetRecordStore: assetStore,
          custody: _RecordingCustody(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _openAlbumMenu(tester);

    // Everything hidden is cloud-native, so "back up this album" is not a
    // question any more — the only fork is whether a bucket exists.
    expect(find.textContaining('Back up this album'), findsNothing);
    expect(find.byType(CupertinoSwitch), findsNothing);
  });
}

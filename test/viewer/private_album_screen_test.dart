import 'dart:async';

import 'package:photos_vault/vault/hidden_backup.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/library_custody.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/viewer/asset_grid.dart';
import 'package:photos_vault/viewer/private_album_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';

import '../settings/fake_secure_store.dart';
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
    List<AssetRecord> records, {
    Future<bool> Function(int count)? askHeif,
    Set<String> restored = const {},
  }) async {
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

/// Holds each `putBack` until [openAll], so a test can act mid-run.
class _GatedCustody implements LibraryCustody {
  final returned = <String>[];
  final waiting = <Completer<void>>[];

  void openAll() {
    for (final gate in waiting) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  Future<CustodyResult> putBack(AssetRecord record) async {
    final gate = Completer<void>();
    waiting.add(gate);
    await gate.future;
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

/// A targets store holding one bucket. Hiding with none configured makes
/// this app's container the only copy of the photo, which now earns its own
/// confirmation — and these tests are about the ordinary case, where the
/// copy has somewhere to go.
Future<BackupTargetsStore> _storeWithBucket() async {
  final store = BackupTargetsStore(store: FakeSecureStore());
  await store.add(
    accessKeyId: 'AKIA',
    secretAccessKey: 'secret',
    region: 'us-east-1',
    bucket: 'bucket',
    prefix: 'photos/',
  );
  return store;
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

    expect(find.text('Nothing hidden yet.'), findsOneWidget);
  });

  testWidgets('holding a photo selects it, and sweeping picks up the next', (
    tester,
  ) async {
    final assetStore = FakeAssetRecordStore();
    for (final id in ['a', 'b']) {
      await assetStore.upsert(
        localId: 'manual:$id',
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/$id.jpg',
      );
      await assetStore.setPasscodeHash('manual:$id', _hash);
    }

    await tester.pumpWidget(
      _wrap(
        PrivateAlbumScreen(passcodeHash: _hash, assetRecordStore: assetStore),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('2 items'), findsOneWidget);

    final hold = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('manual:a'))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await hold.moveTo(tester.getCenter(find.byKey(const ValueKey('manual:b'))));
    await hold.up();
    await tester.pumpAndSettle();

    expect(find.text('Unhide 2 Items'), findsOneWidget);
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

      await tester.tap(find.text('Unhide 2 Items'));
      // Un-hiding checks the file on disk: real I/O, outside fake time.
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(find.text('Nothing hidden yet.'), findsOneWidget);
      expect((await assetStore.getByLocalId('manual:a'))!.passcodeHash, isNull);
      expect((await assetStore.getByLocalId('manual:b'))!.passcodeHash, isNull);
    },
  );

  testWidgets('Move to Library takes what was selected when tapped, once', (
    tester,
  ) async {
    final assetStore = FakeAssetRecordStore();
    for (final id in ['a', 'b', 'c']) {
      await assetStore.upsert(
        localId: 'manual:$id',
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/$id.jpg',
      );
      await assetStore.setPasscodeHash('manual:$id', _hash);
    }
    final custody = _GatedCustody();

    await tester.pumpWidget(
      _wrap(
        PrivateAlbumScreen(
          passcodeHash: _hash,
          assetRecordStore: assetStore,
          custody: custody,
          targetsStore: await _storeWithBucket(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:a')));
    await tester.tap(find.byKey(const ValueKey('manual:b')));
    await tester.pump();

    await tester.tap(find.text('Unhide 2 Items'));
    for (var i = 0; i < 5 && custody.waiting.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(custody.waiting, isNotEmpty, reason: 'mid-run');

    // While it runs: the selection changes, and the button is tapped again.
    await tester.tap(find.byKey(const ValueKey('manual:c')));
    await tester.pump();
    await tester.tap(find.textContaining('Unhide'));
    await tester.pump();

    for (var i = 0; i < 20; i++) {
      custody.openAll();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(custody.returned, ['manual:a', 'manual:b']);
    expect((await assetStore.getByLocalId('manual:a'))!.passcodeHash, isNull);
    expect((await assetStore.getByLocalId('manual:b'))!.passcodeHash, isNull);
    expect((await assetStore.getByLocalId('manual:c'))!.passcodeHash, _hash);
  });

  testWidgets('Done during select mode discards the selection', (tester) async {
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
    await tester.tap(find.byKey(const ValueKey('privateSelectionDone')));
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
          PrivateAlbumScreen(
            passcodeHash: _hash,
            assetRecordStore: assetStore,
            // Un-hiding names the buckets its carriers wait in.
            targetsStore: await _storeWithBucket(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The page's own actions sit on the bar, not behind a "…".
      await _openAlbumMenu(tester);
      await tester.tap(find.text('Delete Hidden Album'));
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
          targetsStore: await _storeWithBucket(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:free')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide 1'));
    await tester.pumpAndSettle();
    // Asked up front now, so the rest can carry on behind the grid.
    await tester.tap(find.text('Keep Originals'));
    await tester.pumpAndSettle();

    // Straight through: the OS puts up its own confirmation for the
    // delete, and a second dialog of ours asking the same thing is how
    // people learn to tap past both.
    expect(find.textContaining('removed from your iPhone'), findsNothing);

    // The album is already open, so its passcode isn't asked for again.
    expect((await assetStore.getByLocalId('manual:free'))!.passcodeHash, _hash);
    expect(custody.takenOut, ['manual:free'], reason: 'gone from Photos');
  });

  testWidgets('hiding with nowhere to put the copy asks first', (tester) async {
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
          // No bucket: hiding takes the photo out of Photos, so this app's
          // container becomes the only copy in existence — and iOS deletes
          // that container with the app.
          targetsStore: BackupTargetsStore(store: FakeSecureStore()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('manual:free')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide 1'));
    await tester.pumpAndSettle();

    expect(find.text('This Phone Will Have the Only Copy'), findsOneWidget);

    // Backing out leaves the photo exactly where it was.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(custody.takenOut, isEmpty);
    expect(
      (await assetStore.getByLocalId('manual:free'))!.passcodeHash,
      isNull,
    );
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
          targetsStore: await _storeWithBucket(),
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
    await tester.tap(find.text('Hide 3'));
    await tester.pumpAndSettle();
    // Asked up front now, so the rest can carry on behind the grid.
    await tester.tap(find.text('Keep Originals'));
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

  group('back swipe from the left edge', () {
    Future<FakeAssetRecordStore> pushAlbum(WidgetTester tester) async {
      final assetStore = FakeAssetRecordStore();
      for (var i = 0; i < 40; i++) {
        await assetStore.upsert(
          localId: 'manual:$i',
          contentHash: '$i',
          platform: 'ios',
          sourceType: AssetSourceType.manualFile,
          sourcePath: '/tmp/$i.jpg',
        );
        await assetStore.setPasscodeHash('manual:$i', _hash);
      }
      await tester.pumpWidget(
        _wrap(CupertinoButton(onPressed: () {}, child: const Text('library'))),
      );
      unawaited(
        Navigator.of(tester.element(find.text('library'))).push(
          CupertinoPageRoute<void>(
            builder: (_) => PrivateAlbumScreen(
              passcodeHash: _hash,
              assetRecordStore: assetStore,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return assetStore;
    }

    /// A thumb's swipe: it starts a little downward, enough for the grid's
    /// scroll to have taken it before.
    Future<void> swipeBack(WidgetTester tester, double y) async {
      final finger = await tester.startGesture(Offset(4, y));
      await finger.moveBy(const Offset(10, 22));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 20; i++) {
        await finger.moveBy(const Offset(30, 2));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await finger.up();
      await tester.pumpAndSettle();
    }

    /// The first tile, which sits in the left column.
    Finder firstTile() => find.byType(AssetTile).first;

    double tileY(WidgetTester tester) => tester.getCenter(firstTile()).dy;

    testWidgets('over a full grid, even when it starts downward', (
      tester,
    ) async {
      await pushAlbum(tester);
      await swipeBack(tester, tileY(tester));
      expect(find.byType(PrivateAlbumScreen), findsNothing);
      expect(find.text('library'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('while selecting', (tester) async {
      await pushAlbum(tester);
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      await swipeBack(tester, tileY(tester));
      expect(find.byType(PrivateAlbumScreen), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('leaves a tap on the edge for the tile under it', (
      tester,
    ) async {
      await pushAlbum(tester);
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      final tile = firstTile();
      expect(tester.getTopLeft(tile).dx, lessThan(12));
      await tester.tapAt(Offset(12, tester.getCenter(tile).dy));
      await tester.pumpAndSettle();
      expect(find.byType(PrivateAlbumScreen), findsOneWidget);
      expect(find.text('Unhide 1 Item'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
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
    // bucket configured — which is this test — it says the honest thing:
    // the photo is encrypted here, and here is the only place it is.
    expect(find.textContaining('no second copy anywhere'), findsOneWidget);
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
    expect(find.textContaining("can't open any of them"), findsNothing);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.textContaining("can't open any of them"), findsOneWidget);

    await tester.tap(find.text('Less'));
    await tester.pumpAndSettle();
    expect(find.textContaining("can't open any of them"), findsNothing);
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

  group('Backup', () {
    tearDown(() => PrivateAlbumScreen.hiddenBackup = null);

    Future<FakeAssetRecordStore> twoHidden() async {
      final store = FakeAssetRecordStore();
      for (final id in ['manual:new', 'manual:done']) {
        await store.upsert(
          localId: id,
          contentHash: id,
          platform: 'ios',
          sourceType: AssetSourceType.manualFile,
          sourcePath: '/tmp/$id.jpg',
        );
        await store.setPasscodeHash(id, _hash);
      }
      await store.updateDerivative(
        'manual:done',
        DerivativeKind.original,
        const DerivativeState(status: UploadStatus.uploaded),
      );
      return store;
    }

    HiddenBackup backupWith(
      FakeAssetRecordStore store,
      Future<void> Function(AssetRecord record) backUp,
    ) => HiddenBackup(
      rest: Duration.zero,
      records: store,
      backUp: backUp,
      albums: () => [_hash],
      ready: () async => true,
    );

    testWidgets('opening the album sends what is not up yet, with no button, '
        'and the photos stay put', (tester) async {
      final store = await twoHidden();
      final sent = <String>[];
      PrivateAlbumScreen.hiddenBackup = backupWith(store, (record) async {
        sent.add(record.localId);
        await store.updateDerivative(
          record.localId,
          DerivativeKind.original,
          const DerivativeState(status: UploadStatus.uploaded),
        );
      });
      await tester.pumpWidget(
        _wrap(PrivateAlbumScreen(passcodeHash: _hash, assetRecordStore: store)),
      );
      await tester.pumpAndSettle();

      expect(sent, ['manual:new']);
      expect(find.byKey(const ValueKey('manual:new')), findsOneWidget);
      expect(find.byKey(const ValueKey('manual:done')), findsOneWidget);
      expect((await store.getByLocalId('manual:new'))!.isFullyBackedUp, isTrue);

      await _openAlbumMenu(tester);
      expect(find.text('Back Up'), findsNothing);
    });

    testWidgets('uploads landing one after another reload the album once '
        'per burst, and the last one shows', (tester) async {
      final store = _CountingReads();
      for (var i = 0; i < 4; i++) {
        await store.upsert(
          localId: 'manual:$i',
          contentHash: '$i',
          platform: 'ios',
          sourceType: AssetSourceType.manualFile,
          sourcePath: '/tmp/$i.jpg',
        );
        await store.setPasscodeHash('manual:$i', _hash);
      }
      PrivateAlbumScreen.hiddenBackup = backupWith(store, (record) async {
        await store.updateDerivative(
          record.localId,
          DerivativeKind.original,
          const DerivativeState(status: UploadStatus.uploaded),
        );
      });
      await tester.pumpWidget(
        _wrap(PrivateAlbumScreen(passcodeHash: _hash, assetRecordStore: store)),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      // Opening reads twice; then one for the four that landed, not one
      // each (which was seven).
      expect(store.reads, lessThanOrEqualTo(3));
      for (var i = 0; i < 4; i++) {
        expect(
          (await store.getByLocalId('manual:$i'))!.isFullyBackedUp,
          isTrue,
        );
      }
    });

    testWidgets('a failure is one line saying why', (tester) async {
      final store = await twoHidden();
      PrivateAlbumScreen.hiddenBackup = backupWith(
        store,
        (_) async => throw Exception('No bucket to back up to'),
      );
      await tester.pumpWidget(
        _wrap(PrivateAlbumScreen(passcodeHash: _hash, assetRecordStore: store)),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining("1 photo wasn't backed up", skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('No bucket to back up to', skipOffstage: false),
        findsOneWidget,
      );
    });
  });
}

class _CountingReads extends FakeAssetRecordStore {
  var reads = 0;

  @override
  Future<List<AssetRecord>> forPasscodeHash(String hash) {
    reads++;
    return super.forPasscodeHash(hash);
  }
}

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/asset_grid.dart';

import 'fake_asset_record_store.dart';

Future<void> addPhotos(FakeAssetRecordStore store, [int n = 40]) async {
  for (var i = 0; i < n; i++) {
    await store.upsert(
      localId: 'manual:p$i',
      contentHash: 'p$i',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/p$i.jpg',
      createdAt: DateTime(2026, 1, 1 + i % 28),
    );
  }
}

/// Pushes [screen] over a home page, then swipes from x=4 starting downward;
/// the screen must pop. Run under the iOS platform variant.
Future<void> expectEdgeSwipeLeaves(
  WidgetTester tester,
  Widget Function() screen,
  Type screenType,
) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    CupertinoApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: CupertinoButton(onPressed: () {}, child: const Text('home')),
    ),
  );
  Navigator.of(tester.element(find.text('home')))
      .push(CupertinoPageRoute<void>(builder: (_) => screen()));
  await tester.pumpAndSettle();
  expect(find.byType(screenType), findsOneWidget);

  final y = find.byType(AssetTile).evaluate().isEmpty
      ? 300.0
      : tester.getCenter(find.byType(AssetTile).first).dy;
  final finger = await tester.startGesture(Offset(4, y));
  await finger.moveBy(const Offset(10, 22));
  await tester.pump(const Duration(milliseconds: 16));
  for (var i = 0; i < 20; i++) {
    await finger.moveBy(const Offset(30, 2));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await finger.up();
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));

  expect(find.byType(screenType), findsNothing);
  expect(find.text('home'), findsOneWidget);
}

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/detail_screen.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';
import '../support/fake_travel_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

AssetRecord _photo({String? location, double? lat, double? lng}) => AssetRecord(
  localId: 'a',
  contentHash: 'a',
  platform: 'ios',
  createdAt: DateTime(2024, 5, 4, 15, 30),
  updatedAt: DateTime(2024, 5, 4),
  sourceType: AssetSourceType.manualFile,
  sourcePath: '/tmp/a.jpg',
  location: location,
  latitude: lat,
  longitude: lng,
);

Widget _detail(AssetRecord record, {FakeTravelStore? travel}) => _wrap(
  DetailScreen(
    records: [record],
    initialIndex: 0,
    assetRecordStore: FakeAssetRecordStore(),
    personStore: FakePersonStore(),
    onDelete: (_) async => true,
    resolvePlaceName: (_) async => null,
    travelStore: travel,
  ),
);

Future<void> _toPanel(WidgetTester tester) async {
  await tester.pump();
  await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a photo with a place offers no impression row', (tester) async {
    await tester.pumpWidget(
      _detail(
        _photo(location: 'Kyoto, Japan', lat: 35, lng: 135.7),
        travel: FakeTravelStore(),
      ),
    );
    await _toPanel(tester);
    expect(find.byKey(const ValueKey('detailTravel')), findsNothing);
    expect(find.text('Add an Impression'), findsNothing);
  });

  testWidgets('the file name is a row of the details table', (tester) async {
    await tester.pumpWidget(_detail(_photo()));
    await _toPanel(tester);
    final row = find.byKey(const ValueKey('detailFileName'));
    await tester.ensureVisible(row);
    expect(
      find.descendant(of: row, matching: find.text('a.jpg')),
      findsOneWidget,
    );
  });
}

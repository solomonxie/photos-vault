import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/travel.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/detail_screen.dart';
import 'package:photos_vault/viewer/place_screen.dart';

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
  testWidgets('a photo with a place starts a diary entry there, itself in '
      'it', (tester) async {
    final travel = FakeTravelStore();
    await tester.pumpWidget(
      _detail(
        _photo(location: 'Kyoto, Japan', lat: 35, lng: 135.7),
        travel: travel,
      ),
    );
    await _toPanel(tester);
    final row = find.byKey(const ValueKey('detailTravel'));
    expect(find.text('Write About This Place'), findsOne);
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('travelEntryTitle')),
      'Golden afternoon',
    );
    await tester.tap(find.byKey(const ValueKey('travelEntrySave')));
    await tester.pumpAndSettle();

    final city = travel.placesById.values.single;
    expect((city.name, city.country, city.isCity), ('Kyoto', 'Japan', true));
    final entry = travel.entriesById.values.single;
    expect(entry.placeId, city.id);
    expect(entry.at, DateTime(2024, 5, 4));
    expect(travel.links[(LinkOwner.entry, entry.id)], [
      const TravelLink(LinkTarget.asset, 'a'),
    ]);
    expect(find.text('Diary for Kyoto (1)'), findsOne);

    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byType(PlaceScreen), findsOne);
  });

  testWidgets('no travel diary to hand, or no place: no row', (tester) async {
    await tester.pumpWidget(_detail(_photo(location: 'Kyoto, Japan')));
    await _toPanel(tester);
    expect(find.byKey(const ValueKey('detailTravel')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_detail(_photo(), travel: FakeTravelStore()));
    await _toPanel(tester);
    expect(find.byKey(const ValueKey('detailTravel')), findsNothing);
  });
}

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/place_search.dart';
import 'package:photos_vault/photos/travel.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/native_map.dart';
import 'package:photos_vault/viewer/place_screen.dart';
import 'package:photos_vault/viewer/travel_entry_editor.dart';
import 'package:photos_vault/viewer/places_screen.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';
import '../support/fake_travel_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

const _channel = MethodChannel('test/travel_places');

PlaceSearch _search({List<Map<String, Object?>> results = const []}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        _channel,
        (call) async => call.method == 'search' ? results : null,
      );
  return PlaceSearch(
    channel: _channel,
    reverseGeocode: (lat, lng) async => [
      geo.Placemark(locality: 'Kyoto', country: 'Japan'),
    ],
  );
}

AssetRecord _photo(String id, {String? location}) => AssetRecord(
  localId: id,
  contentHash: id,
  platform: 'ios',
  createdAt: DateTime(2024, 5, 4),
  updatedAt: DateTime(2024, 5, 4),
  sourceType: AssetSourceType.manualFile,
  sourcePath: '/tmp/$id.jpg',
  location: location,
);

/// Room for a place page's cover, map and visits above its lists.
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('countries at the top; each place opens what is inside it', (
    tester,
  ) async {
    final store = FakeTravelStore();
    final kyoto = await store.findOrCreateCity(
      name: 'Kyoto',
      country: 'Japan',
      lat: 35,
      lng: 135.7,
    );
    final gion = await store.createPlace(
      name: 'Gion',
      kind: PlaceKind.area,
      lat: 35.0,
      lng: 135.77,
      parentId: kyoto.id,
      country: 'Japan',
    );
    final cafe = await store.createPlace(
      name: 'Kagizen',
      kind: PlaceKind.point,
      lat: 35.0,
      lng: 135.77,
      parentId: gion.id,
      country: 'Japan',
      category: 'Cafe',
    );
    await store.findOrCreateCity(
      name: 'Lisbon',
      country: 'Portugal',
      lat: 38.7,
      lng: -9.1,
    );
    await store.saveEntry(
      store
          .newEntry(placeId: cafe.id, kind: EntryKind.impression)
          .copyWith(text: 'Matcha warabi'),
    );
    await tester.pumpWidget(
      _wrap(PlacesScreen(travelStore: store, placeSearch: _search())),
    );
    await tester.pumpAndSettle();

    // The map under a list, every place a pin.
    expect(find.text('Japan'), findsOne);
    expect(find.text('Portugal'), findsOne);
    // The whole tree at once; an area shows as a pin under its city.
    expect(find.text('Kyoto'), findsOne);
    expect(find.text('Lisbon'), findsOne);
    expect(find.byKey(ValueKey('place-pin-${gion.id}')), findsOne);
    expect(find.byKey(ValueKey('place-pin-${cafe.id}')), findsOne);
    expect(
      tester.widget<NativeMap>(find.byType(NativeMap)).pins.map((p) => p.title),
      containsAll(['Kyoto', 'Gion', 'Kagizen', 'Lisbon']),
    );

    // A note on a pin is the country's too, and says where it was.
    await tester.tap(find.text('Japan'));
    await tester.pumpAndSettle();
    expect(find.text('Matcha warabi'), findsOne);
    expect(find.textContaining('at Kagizen'), findsOne);
    expect(find.text('Places'), findsOne);

    await tester.tap(find.text('Kyoto'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        ValueKey(
          'placePath-${store.placesById.values.firstWhere((p) => p.isCountry).id}',
        ),
      ),
      findsOne,
    );
    expect(find.text('Matcha warabi'), findsOne);
    await tester.tap(find.text('Gion'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kagizen'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cafe'), findsWidgets);
    // Its own: no "at".
    expect(find.text('Matcha warabi'), findsOne);
    expect(find.textContaining('at Kagizen'), findsNothing);
  });

  testWidgets('nothing yet: says how to start', (tester) async {
    await tester.pumpWidget(
      _wrap(
        PlacesScreen(travelStore: FakeTravelStore(), placeSearch: _search()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('travelPlacesEmpty')), findsOne);
  });

  testWidgets('a business found by search is filed under country and city', (
    tester,
  ) async {
    final store = FakeTravelStore();
    await tester.pumpWidget(
      _wrap(
        PlacesScreen(
          travelStore: store,
          placeSearch: _search(
            results: [
              {
                'name': 'Kinkaku-ji',
                'kind': 'point',
                'locality': 'Kyoto',
                'country': 'Japan',
                'address': '1 Kinkakujicho',
                'category': 'Landmark',
                'lat': 35.03,
                'lng': 135.72,
              },
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('travelAddPlace')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('travelPlaceSearch')),
      'kinkaku',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('travelSearchResult-0')));
    await tester.pumpAndSettle();

    final places = await store.places();
    final country = places.singleWhere((p) => p.isCountry);
    final city = places.singleWhere((p) => p.isCity);
    final pin = places.singleWhere((p) => p.kind == PlaceKind.point);
    expect(country.name, 'Japan');
    expect(city.parentId, country.id);
    expect(pin.parentId, city.id);
    expect((pin.address, pin.category), ('1 Kinkakujicho', 'Landmark'));
    expect(find.byType(PlaceScreen), findsOne);

    // Found again: the same place, not a second one.
    await savePlaceResult(
      store,
      _search(),
      const PlaceResult(
        name: 'Kinkaku-ji',
        locality: 'Kyoto',
        country: 'Japan',
        lat: 35.031,
        lng: 135.721,
      ),
    );
    expect(await store.places(), hasLength(3));
  });

  testWidgets('inside a place: a found place, an area by name, a pin', (
    tester,
  ) async {
    final store = FakeTravelStore();
    final kyoto = await store.findOrCreateCity(
      name: 'Kyoto',
      country: 'Japan',
      lat: 35,
      lng: 135.7,
    );
    await tester.pumpWidget(
      _wrap(
        PlaceScreen(
          travelStore: store,
          placeSearch: _search(
            results: [
              {
                'name': 'Nishiki Market',
                'kind': 'point',
                'locality': 'Osaka',
                'country': 'Japan',
                'lat': 35.005,
                'lng': 135.765,
              },
            ],
          ),
          placeId: kyoto.id,
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> addInside(String query) async {
      await tester.ensureVisible(find.byKey(const ValueKey('placeAddPoint')));
      await tester.tap(find.byKey(const ValueKey('placeAddPoint')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('travelPlaceSearch')),
        query,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }

    await addInside('nishiki');
    await tester.tap(find.byKey(const ValueKey('travelSearchResult-0')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    // Where it was added, whatever MapKit's town says.
    expect(
      store.placesById.values
          .singleWhere((p) => p.name == 'Nishiki Market')
          .parentId,
      kyoto.id,
    );

    await addInside('Higashiyama');
    await tester.tap(find.byKey(const ValueKey('placeAddArea')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    final area = store.placesById.values.singleWhere(
      (p) => p.name == 'Higashiyama',
    );
    expect((area.kind, area.parentId), (PlaceKind.point, kyoto.id));

    tester.widget<NativeMap>(find.byType(NativeMap)).onLongPress!(35.01, 135.7);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('travelPinName')),
      'Our ryokan',
    );
    await tester.tap(find.byKey(const ValueKey('travelPinSave')));
    await tester.pumpAndSettle();
    final pin = store.placesById.values.singleWhere(
      (p) => p.name == 'Our ryokan',
    );
    expect((pin.kind, pin.parentId), (PlaceKind.point, kyoto.id));
  });

  testWidgets('a pin dropped on the top map finds its country and city', (
    tester,
  ) async {
    final store = FakeTravelStore();
    await tester.pumpWidget(
      _wrap(PlacesScreen(travelStore: store, placeSearch: _search())),
    );
    await tester.pumpAndSettle();
    tester.widget<NativeMap>(find.byType(NativeMap)).onLongPress!(35.01, 135.7);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('travelPinName')),
      'Our ryokan',
    );
    await tester.tap(find.byKey(const ValueKey('travelPinSave')));
    await tester.pumpAndSettle();

    final pin = (await store.places()).singleWhere(
      (p) => p.kind == PlaceKind.point,
    );
    final city = store.placesById[pin.parentId]!;
    expect(city.name, 'Kyoto');
    expect(store.placesById[city.parentId]!.name, 'Japan');
  });

  testWidgets('moved into another place, or to the top', (tester) async {
    final store = FakeTravelStore();
    final kyoto = await store.findOrCreateCity(
      name: 'Kyoto',
      country: 'Japan',
      lat: 35,
      lng: 135.7,
    );
    final loose = await store.createPlace(
      name: 'Fushimi Inari',
      kind: PlaceKind.point,
      lat: 34.97,
      lng: 135.77,
    );
    await tester.pumpWidget(
      _wrap(
        PlaceScreen(
          travelStore: store,
          placeSearch: _search(),
          placeId: loose.id,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('placeMore')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('placeMove')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('placeMoveTo-${kyoto.id}')));
    await tester.pumpAndSettle();
    expect(store.placesById[loose.id]!.parentId, kyoto.id);
    expect(find.byKey(ValueKey('placePath-${kyoto.id}')), findsOne);

    await tester.tap(find.byKey(const ValueKey('placeMore')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('placeMove')));
    await tester.pumpAndSettle();
    // Not into itself or what's inside it.
    expect(find.byKey(ValueKey('placeMoveTo-${loose.id}')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('placeMoveTop')));
    await tester.pumpAndSettle();
    expect(store.placesById[loose.id]!.parentId, isNull);
  });

  testWidgets(
    'every place at once: country and city from the photos, pins under their city',
    (tester) async {
      final store = FakeTravelStore();
      final kyoto = await store.findOrCreateCity(
        name: 'Kyoto',
        country: 'Japan',
        lat: 35,
        lng: 135.7,
      );
      final cafe = await store.createPlace(
        name: 'Kagizen',
        kind: PlaceKind.point,
        lat: 35,
        lng: 135.77,
        parentId: kyoto.id,
        country: 'Japan',
      );
      await tester.pumpWidget(
        _wrap(
          PlacesScreen(
            travelStore: store,
            placeSearch: _search(),
            placeGroups: {
              'Kyoto, Japan': [_photo('a'), _photo('b')],
              'Osaka, Japan': [_photo('c')],
              'Lisbon, Portugal': [_photo('d')],
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('travelPlacesEmpty')), findsNothing);
      final rows = tester
          .widgetList<CupertinoListTile>(find.byType(CupertinoListTile))
          .map((t) => (t.key as ValueKey<String>).value)
          .toList();
      expect(rows, [
        'place-country-Japan',
        'place-city-Kyoto',
        'place-pin-${cafe.id}',
        'place-city-Osaka',
        'place-country-Portugal',
        'place-city-Lisbon',
      ]);

      // Known only from photos: saved on first open, and its page opens.
      await tester.tap(find.byKey(const ValueKey('place-city-Osaka')));
      await tester.pumpAndSettle();
      expect(find.byType(PlaceScreen), findsOne);
      final osaka = (await store.places()).where((p) => p.name == 'Osaka');
      expect(osaka.single.kind, PlaceKind.city);
      expect(osaka.single.country, 'Japan');
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(ValueKey('place-pin-${cafe.id}')));
      await tester.pumpAndSettle();
      expect(find.byType(PlaceScreen), findsOne);
    },
  );

  testWidgets('a country shows its top five cities; the rest fold', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final groups = {
      for (var i = 0; i < 7; i++)
        'C$i, Canada': [for (var n = 0; n < 7 - i; n++) _photo('c$i-$n')],
    };
    await tester.pumpWidget(
      _wrap(
        PlacesScreen(
          travelStore: FakeTravelStore(),
          placeSearch: _search(),
          placeGroups: groups,
        ),
      ),
    );
    await tester.pumpAndSettle();
    List<String> cities() => [
      for (final t in tester.widgetList<CupertinoListTile>(
        find.byType(CupertinoListTile),
      ))
        if ((t.key as ValueKey<String>).value case final k
            when k.startsWith('place-city-'))
          k.substring('place-city-'.length),
    ];
    expect(cities(), ['C0', 'C1', 'C2', 'C3', 'C4']);
    expect(find.text('2 More Cities'), findsOne);

    await tester.tap(find.byKey(const ValueKey('place-fold-Canada')));
    await tester.pumpAndSettle();
    expect(cities(), ['C0', 'C1', 'C2', 'C3', 'C4', 'C5', 'C6']);
    await tester.tap(find.text('Show Less'));
    await tester.pumpAndSettle();
    expect(cities(), hasLength(5));
  });

  test('a pin\'s photos are the ones taken within its reach', () {
    AssetRecord at(String id, double lat, double lng) => AssetRecord(
      localId: id,
      contentHash: id,
      platform: 'ios',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
      sourceType: AssetSourceType.manualFile,
      latitude: lat,
      longitude: lng,
    );
    final pin = Place(
      id: 'p',
      name: 'Cafe',
      kind: PlaceKind.point,
      lat: 49.28,
      lng: -123.12,
      createdAt: DateTime(2024),
    );
    final near = photosNear(pin, {
      'Vancouver, Canada': [
        at('door', 49.2801, -123.1201),
        at('block', 49.282, -123.12),
        at('across town', 49.25, -123.10),
      ],
      'Vancouver': [at('door', 49.2801, -123.1201)],
    });
    expect([for (final r in near) r.localId], ['door', 'block']);
  });

  testWidgets('a place page: description, pins, impressions, photos folded', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = FakeTravelStore();
    final city = await store.findOrCreateCity(
      name: 'Kyoto',
      country: 'Japan',
      lat: 35,
      lng: 135.7,
    );
    final pin = await store.createPlace(
      name: 'Gion',
      kind: PlaceKind.point,
      lat: 35.0037,
      lng: 135.7788,
      parentId: city.id,
      country: 'Japan',
    );
    await tester.pumpWidget(
      _wrap(
        PlaceScreen(
          travelStore: store,
          placeSearch: _search(),
          placeId: city.id,
          assetRecordStore: FakeAssetRecordStore(),
          placeGroups: {
            'Kyoto, Japan': [for (var i = 0; i < 20; i++) _photo('k$i')],
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('travelPlace-${pin.id}')), findsOne);
    expect(find.byKey(const ValueKey('placeAddImpression')), findsOne);
    expect(find.byKey(const ValueKey('placePhotoGrid')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('placePhotos')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('placePhotoGrid')), findsOne);
    expect(find.text('See All 20'), findsOne);

    await tester.tap(find.byKey(const ValueKey('placeDescription')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('placeDescriptionField')),
      'Old town, east of the river',
    );
    await tester.tap(find.byKey(const ValueKey('placeDescriptionSave')));
    await tester.pumpAndSettle();
    expect(
      (await store.places()).firstWhere((p) => p.id == city.id).description,
      'Old town, east of the river',
    );
    expect(find.text('Old town, east of the river'), findsOne);

    await tester.tap(find.byKey(ValueKey('travelPlace-${pin.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Gion'), findsWidgets);
    // A pin holds no pins of its own.
    expect(find.byKey(const ValueKey('placeAddPoint')), findsNothing);
    expect(find.byKey(const ValueKey('placeAddImpression')), findsOne);
  });

  test('places as a tree: a missing parent or a loop files at the top', () {
    Place at(String id, String? parent) => Place(
      id: id,
      name: id,
      kind: PlaceKind.point,
      lat: 0,
      lng: 0,
      parentId: parent,
      createdAt: DateTime(2024),
    );
    final tree = placeTree([
      at('jp', null),
      at('kyoto', 'jp'),
      at('gion', 'kyoto'),
      at('orphan', 'gone'),
      at('a', 'b'),
      at('b', 'a'),
    ]);
    expect(tree[null]!.map((p) => p.id), ['a', 'b', 'jp', 'orphan']);
    expect(placeAndBelow('jp', tree), {'jp', 'kyoto', 'gion'});
  });

  test('a city takes the photos filed under its name', () {
    final city = Place(
      id: 'c',
      name: 'Kyoto',
      kind: PlaceKind.city,
      lat: 0,
      lng: 0,
      country: 'Japan',
      createdAt: DateTime(2024),
    );
    final groups = {
      'Kyoto, Japan': [_photo('a')],
      'kyoto': [_photo('b')],
      'Osaka, Japan': [_photo('c')],
    };
    expect(photosNamedFor(city, groups).map((r) => r.localId), ['a', 'b']);
    expect(
      photosNamedFor(
        Place(
          id: 'j',
          name: 'Japan',
          kind: PlaceKind.country,
          lat: 0,
          lng: 0,
          createdAt: DateTime(2024),
        ),
        groups,
      ).map((r) => r.localId),
      ['a', 'c'],
    );
    expect(
      photosNamedFor(
        Place(
          id: 'p',
          name: 'Kyoto',
          kind: PlaceKind.point,
          lat: 0,
          lng: 0,
          createdAt: DateTime(2024),
        ),
        groups,
      ),
      isEmpty,
    );
  });

  group('place page', () {
    late FakeTravelStore store;
    late Place kyoto;

    setUp(() async {
      store = FakeTravelStore();
      kyoto = await store.createPlace(
        name: 'Kyoto',
        kind: PlaceKind.city,
        lat: 35,
        lng: 135.7,
        country: 'Japan',
      );
    });

    Widget page({FakePersonStore? people}) => _wrap(
      PlaceScreen(
        travelStore: store,
        placeSearch: _search(),
        placeId: kyoto.id,
        personStore: people,
        assetRecordStore: FakeAssetRecordStore(),
        placeGroups: {
          'Kyoto, Japan': [_photo('a')],
        },
      ),
    );

    testWidgets(
      'an impression is one box of text, at the place it was written from',
      (tester) async {
        _tall(tester);
        await tester.pumpWidget(page());
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('placeEntry-')), findsNothing);
        expect(find.byKey(const ValueKey('placePhotos')), findsOne);

        await tester.tap(find.byKey(const ValueKey('placeAddImpression')));
        await tester.pumpAndSettle();
        // Nothing to fill in but the text; where and when are shown.
        expect(find.byKey(const ValueKey('travelEntryText')), findsOne);
        expect(find.byKey(const ValueKey('travelEntryMore')), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('travelEntryDate')),
            matching: find.text('Kyoto'),
          ),
          findsOne,
        );
        await tester.enterText(
          find.byKey(const ValueKey('travelEntryText')),
          '# Temples\nWalked **all** day.',
        );
        await tester.tap(find.byKey(const ValueKey('travelEntrySave')));
        await tester.pumpAndSettle();

        final entry = store.entriesById.values.single;
        expect(
          (entry.kind, entry.placeId, entry.title, entry.rating),
          (EntryKind.impression, kyoto.id, '', null),
        );
        expect(store.links[(LinkOwner.entry, entry.id)] ?? const [], isEmpty);

        await tester.tap(find.textContaining('Walked'));
        await tester.pumpAndSettle();
        expect(find.byType(TravelEntryScreen), findsOne);
        expect(find.text('Temples'), findsOne);
      },
    );

    testWidgets('an entry is deleted from its editor', (tester) async {
      _tall(tester);
      final saved = await store.saveEntry(
        store
            .newEntry(placeId: kyoto.id, kind: EntryKind.diary)
            .copyWith(text: 'Gone soon'),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gone soon'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('travelEntryEdit')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('travelEntryDelete')),
      );
      await tester.tap(find.byKey(const ValueKey('travelEntryDelete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('travelEntryDeleteConfirm')));
      await tester.pumpAndSettle();

      expect(store.entriesById, isNot(contains(saved.id)));
      expect(find.byType(PlaceScreen), findsOne);
      expect(find.text('Gone soon'), findsNothing);
    });

    testWidgets('a place in use is not deleted; an empty one is', (
      tester,
    ) async {
      _tall(tester);
      await store.saveEntry(
        store.newEntry(placeId: kyoto.id, kind: EntryKind.diary),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('placeMore')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('placeDelete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('placeDeleteInUse')), findsOne);
      expect(store.placesById, contains(kyoto.id));
    });

    testWidgets('renamed from its menu', (tester) async {
      _tall(tester);
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('placeMore')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('placeRename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('placeRenameField')),
        '京都',
      );
      await tester.tap(find.byKey(const ValueKey('placeRenameSave')));
      await tester.pumpAndSettle();
      expect(store.placesById[kyoto.id]!.name, '京都');
    });
  });
}

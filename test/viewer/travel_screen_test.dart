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
import 'package:photos_vault/viewer/route_list_view.dart';
import 'package:photos_vault/viewer/travel_entry_editor.dart';
import 'package:photos_vault/viewer/travel_screen.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('places by country, cities with what is inside them', (
    tester,
  ) async {
    final store = FakeTravelStore();
    final kyoto = await store.createPlace(
      name: 'Kyoto',
      kind: PlaceKind.city,
      lat: 35,
      lng: 135.7,
      country: 'Japan',
    );
    await store.createPlace(
      name: 'Kinkaku-ji',
      kind: PlaceKind.point,
      lat: 35.03,
      lng: 135.72,
      parentId: kyoto.id,
      country: 'Japan',
    );
    await store.findOrCreateCity(
      name: 'Lisbon',
      country: 'Portugal',
      lat: 38.7,
      lng: -9.1,
    );
    await store.saveEntry(
      store.newEntry(placeId: kyoto.id, kind: EntryKind.diary),
    );
    await tester.pumpWidget(
      _wrap(TravelScreen(travelStore: store, placeSearch: _search())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('nativeMapPlaceholder')), findsOne);
    expect(find.text('Japan'), findsOne);
    expect(find.text('Portugal'), findsOne);
    expect(find.text('1 place inside'), findsOne);
    // The point sits on Kyoto's page, not in the country list.
    expect(find.text('Kinkaku-ji'), findsNothing);
    expect(
      tester.widget<NativeMap>(find.byType(NativeMap)).pins.map((p) => p.title),
      containsAll(['Kyoto', 'Kinkaku-ji', 'Lisbon']),
    );

    await tester.tap(find.text('Kyoto'));
    await tester.pumpAndSettle();
    expect(find.byType(PlaceScreen), findsOne);
    expect(find.text('Kinkaku-ji'), findsOne);
    expect(find.text('Places in Kyoto'), findsOne);
  });

  testWidgets('nothing yet: says how to start', (tester) async {
    await tester.pumpWidget(
      _wrap(
        TravelScreen(travelStore: FakeTravelStore(), placeSearch: _search()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('travelPlacesEmpty')), findsOne);
  });

  testWidgets('a point found by search is filed under its city', (
    tester,
  ) async {
    final store = FakeTravelStore();
    await tester.pumpWidget(
      _wrap(
        TravelScreen(
          travelStore: store,
          placeSearch: _search(
            results: [
              {
                'name': 'Kinkaku-ji',
                'locality': 'Kyoto',
                'country': 'Japan',
                'lat': 35.03,
                'lng': 135.72,
                'isCity': false,
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
    final city = places.singleWhere((p) => p.isCity);
    final point = places.singleWhere((p) => !p.isCity);
    expect((city.name, city.country), ('Kyoto', 'Japan'));
    expect(point.parentId, city.id);
    expect(find.byType(PlaceScreen), findsOne);
    expect(find.text('in Kyoto'), findsOne);

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
        isCity: false,
      ),
    );
    expect(await store.places(), hasLength(2));
  });

  testWidgets('a pin held down on the map is named and placed', (tester) async {
    final store = FakeTravelStore();
    await tester.pumpWidget(
      _wrap(TravelScreen(travelStore: store, placeSearch: _search())),
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

    final point = (await store.places()).singleWhere((p) => !p.isCity);
    expect(point.name, 'Our ryokan');
    expect(store.placesById[point.parentId]!.name, 'Kyoto');
    expect(find.text('Our ryokan'), findsWidgets);
  });

  testWidgets('routes and photos are tabs of the same screen', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(
      _wrap(
        TravelScreen(
          travelStore: FakeTravelStore(),
          placeSearch: _search(),
          placeGroups: {
            'Kyoto, Japan': [_photo('a'), _photo('b')],
          },
          onOpenGroup: (title, _) => opened.add(title),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Routes'));
    await tester.pumpAndSettle();
    expect(find.byType(RouteListView), findsOne);
    expect(find.byKey(const ValueKey('travelAddPlace')), findsNothing);

    await tester.tap(find.text('Photos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kyoto, Japan'));
    expect(opened, ['Kyoto, Japan']);
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

    testWidgets('a diary entry is written, read, and linked to a person', (
      tester,
    ) async {
      final people = FakePersonStore();
      final mia = await people.create(name: 'Mia');
      await tester.pumpWidget(page(people: people));
      await tester.pumpAndSettle();
      expect(find.text('Nothing written here yet.'), findsOne);
      expect(find.byKey(const ValueKey('placePhotos')), findsOne);

      await tester.tap(find.byKey(const ValueKey('placeWriteDiary')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('travelEntryTitle')),
        'First day',
      );
      await tester.enterText(
        find.byKey(const ValueKey('travelEntryText')),
        '# Temples\nWalked **all** day.',
      );
      await tester.tap(find.byKey(const ValueKey('travelEntryAddPerson')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mia').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('travelEntrySave')));
      await tester.pumpAndSettle();

      final entry = store.entriesById.values.single;
      expect(entry.kind, EntryKind.diary);
      expect(entry.title, 'First day');
      expect(store.links[(LinkOwner.entry, entry.id)], [
        TravelLink(LinkTarget.person, mia.id),
      ]);
      expect(find.text('Diary'), findsOne);

      await tester.tap(find.text('First day'));
      await tester.pumpAndSettle();
      expect(find.byType(TravelEntryScreen), findsOne);
      expect(find.text('Temples'), findsOne);
      expect(find.text('Mia'), findsOne);
    });

    testWidgets('an impression per visit, rated and tagged', (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('placeAddImpression')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('travelEntryStar4')));
      await tester.enterText(
        find.byKey(const ValueKey('travelEntryTags')),
        'quiet, go back',
      );
      await tester.enterText(
        find.byKey(const ValueKey('travelEntryText')),
        'Calm in the rain.',
      );
      await tester.tap(find.byKey(const ValueKey('travelEntrySave')));
      await tester.pumpAndSettle();

      final entry = store.entriesById.values.single;
      expect(entry.kind, EntryKind.impression);
      expect(entry.rating, 4);
      expect(entry.tags, ['quiet', 'go back']);
      expect(find.text('Impressions'), findsOne);
      expect(find.textContaining('★★★★☆'), findsOne);
    });

    testWidgets('an entry is deleted from its editor', (tester) async {
      final saved = await store.saveEntry(
        store
            .newEntry(placeId: kyoto.id, kind: EntryKind.diary)
            .copyWith(title: 'Gone soon'),
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

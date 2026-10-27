import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/place_search.dart';
import 'package:photos_vault/photos/travel.dart';
import 'package:photos_vault/viewer/profile_previews.dart';
import 'package:photos_vault/viewer/route_list_view.dart';
import 'package:photos_vault/viewer/route_screen.dart';

import '../support/fake_travel_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: CupertinoPageScaffold(child: SingleChildScrollView(child: child)),
);

const _channel = MethodChannel('test/route_places');

PlaceSearch _search() =>
    PlaceSearch(channel: _channel, reverseGeocode: (_, _) async => []);

void main() {
  late FakeTravelStore store;

  setUp(() {
    store = FakeTravelStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method != 'search') return null;
          return [
            {
              'name': 'Fushimi Inari',
              'locality': 'Kyoto',
              'country': 'Japan',
              'lat': 34.96,
              'lng': 135.77,
              'isCity': false,
            },
          ];
        });
  });

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<TravelRoute> japan() async {
    final tokyo = await store.findOrCreateCity(
      name: 'Tokyo',
      country: 'Japan',
      lat: 35.68,
      lng: 139.69,
    );
    final kyoto = await store.findOrCreateCity(
      name: 'Kyoto',
      country: 'Japan',
      lat: 35.01,
      lng: 135.77,
    );
    final route = await store.createRoute(
      title: 'Japan',
      starts: DateTime(2025, 11, 2),
    );
    await store.setStops(route.id, [
      RouteStop(placeId: tokyo.id, note: 'Arrived late'),
      RouteStop(placeId: kyoto.id),
    ]);
    await store.saveLeg(
      route.id,
      0,
      const RouteLeg(mode: LegMode.train, note: 'Fuji on the right'),
    );
    return route;
  }

  testWidgets('no routes: says what one is; a new one left empty is not kept', (
    tester,
  ) async {
    tall(tester);
    await tester.pumpWidget(
      _wrap(RouteListView(travelStore: store, placeSearch: _search())),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No routes yet'), findsOne);

    await tester.tap(find.byKey(const ValueKey('routeNew')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('routeTitleField')), findsOne);
    await tester.tap(find.byKey(const ValueKey('routeEditorDone')));
    await tester.pumpAndSettle();
    expect(store.routesById, isEmpty);
    expect(find.textContaining('No routes yet'), findsOne);
  });

  testWidgets('a card shows the route; its page runs stop, leg, stop', (
    tester,
  ) async {
    tall(tester);
    final route = await japan();
    await tester.pumpWidget(
      _wrap(RouteListView(travelStore: store, placeSearch: _search())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Japan'), findsOne);
    expect(find.textContaining('2 stops'), findsOne);
    expect(find.text('Tokyo → Kyoto'), findsOne);

    await tester.tap(find.byKey(ValueKey('routeCard-${route.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('routeStop-0')), findsOne);
    expect(find.byKey(const ValueKey('routeLeg-0')), findsOne);
    expect(find.byKey(const ValueKey('routeStop-1')), findsOne);
    expect(find.text('Arrived late'), findsOne);
    expect(find.text('Train'), findsOne);
    expect(find.text('Fuji on the right'), findsOne);
    expect(find.byKey(const ValueKey('routeLegReview')), findsNothing);
  });

  testWidgets('a reordered leg is flagged on the route page', (tester) async {
    tall(tester);
    final route = await japan();
    final stops = store.stopsOf[route.id]!;
    await store.setStops(route.id, [stops[1], stops[0]]);
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RouteScreen(
          travelStore: store,
          placeSearch: _search(),
          routeId: route.id,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('routeLegReview')), findsOne);
  });

  testWidgets('the editor adds a searched point inside its city, sets a leg '
      'and notes, removes a stop, and deletes the route', (tester) async {
    tall(tester);
    final route = await japan();
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: RouteScreen(
          travelStore: store,
          placeSearch: _search(),
          routeId: route.id,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('routeEdit')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('routeAddStop')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('routePlaceSearch')),
      'fushimi',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('routeFoundPlace-0')));
    await tester.pumpAndSettle();
    final added = store.placesById[store.stopsOf[route.id]![2].placeId]!;
    expect(added.name, 'Fushimi Inari');
    expect(added.isCity, isFalse);
    expect(
      store.placesById[added.parentId]!.name,
      'Kyoto',
      reason: 'joins the Kyoto already here',
    );

    await tester.tap(find.byKey(const ValueKey('routeLegMode-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('routeMode-walk')));
    await tester.pumpAndSettle();
    expect(store.legsOf[route.id]![1].mode, LegMode.walk);

    await tester.enterText(
      find.byKey(const ValueKey('routeStopNote-2')),
      'Ten thousand gates',
    );
    await tester.enterText(
      find.byKey(const ValueKey('routeLegNote-1')),
      'Up the hill',
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(store.stopsOf[route.id]![2].note, 'Ten thousand gates');
    expect(store.legsOf[route.id]![1].note, 'Up the hill');

    await tester.tap(find.byKey(const ValueKey('routeRemoveStop-0')));
    await tester.pumpAndSettle();
    expect(
      [
        for (final s in store.stopsOf[route.id]!)
          store.placesById[s.placeId]!.name,
      ],
      ['Kyoto', 'Fushimi Inari'],
    );

    await tester.enterText(
      find.byKey(const ValueKey('routeTitleField')),
      'Kansai',
    );
    await tester.tap(find.byKey(const ValueKey('routeEditorDone')));
    await tester.pumpAndSettle();
    expect(store.routesById[route.id]!.title, 'Kansai');
    expect(find.text('Kansai'), findsOne, reason: 'the page reloads');

    await tester.tap(find.byKey(const ValueKey('routeEdit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('routeDelete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('routeDeleteConfirm')));
    await tester.pumpAndSettle();
    expect(store.routesById, isEmpty);
    expect(store.placesById, hasLength(3), reason: 'places stay');
  });

  testWidgets('a profile lists the routes and entries a person is in', (
    tester,
  ) async {
    final route = await japan();
    final kyoto = (await store.places()).firstWhere((p) => p.name == 'Kyoto');
    final entry = await store.saveEntry(
      store
          .newEntry(placeId: kyoto.id, kind: EntryKind.impression)
          .copyWith(title: 'Quiet mornings'),
    );
    TravelRoute? openedRoute;
    TravelEntry? openedEntry;
    await tester.pumpWidget(
      _wrap(
        TravelsPreview(
          routes: [store.routesById[route.id]!],
          entries: [entry],
          places: {kyoto.id: kyoto},
          onOpenRoute: (r) => openedRoute = r,
          onOpenEntry: (e) => openedEntry = e,
        ),
      ),
    );
    expect(find.text('Japan'), findsOne);
    expect(find.text('Quiet mornings'), findsOne);
    expect(find.textContaining('Impression · Kyoto'), findsOne);
    await tester.tap(find.text('Japan'));
    await tester.tap(find.text('Quiet mornings'));
    expect(openedRoute?.id, route.id);
    expect(openedEntry?.id, entry.id);
  });
}

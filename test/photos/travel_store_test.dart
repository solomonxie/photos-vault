import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/travel.dart';
import 'package:photos_vault/photos/travel_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late TravelStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('travel_');
    store = TravelStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, 'travel.db'),
    );
  });

  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  Future<Place> city(String name) =>
      store.findOrCreateCity(name: name, country: 'Japan', lat: 35, lng: 135);

  test('a city is found again by name; points sit inside it', () async {
    final kyoto = await city('Kyoto');
    expect((await city('kyoto')).id, kyoto.id);
    final shrine = await store.createPlace(
      name: 'Fushimi Inari',
      kind: PlaceKind.point,
      lat: 34.96,
      lng: 135.77,
      parentId: kyoto.id,
    );
    expect((await store.placesIn(kyoto.id)).single.id, shrine.id);
    expect(await store.places(), hasLength(2));
    expect(await store.deletePlace(kyoto.id), isFalse, reason: 'has a point');
    expect(await store.deletePlace(shrine.id), isTrue);
  });

  test('entries: diary and impressions per visit, counted per place', () async {
    final kyoto = await city('Kyoto');
    final first = store.newEntry(
      placeId: kyoto.id,
      kind: EntryKind.impression,
      at: DateTime(2019, 4, 1),
    );
    await store.saveEntry(
      first.copyWith(text: 'busy', rating: () => 3, tags: ['crowded']),
    );
    final again = store.newEntry(
      placeId: kyoto.id,
      kind: EntryKind.impression,
      at: DateTime(2025, 11, 2),
    );
    await store.saveEntry(again.copyWith(text: 'calm', rating: () => 5));
    final diary = store.newEntry(placeId: kyoto.id, kind: EntryKind.diary);
    await store.saveEntry(
      diary.copyWith(title: 'Day 1', text: '# Arrived', rating: () => 4),
    );

    final impressions = await store.entriesAt(
      kyoto.id,
      kind: EntryKind.impression,
    );
    expect([for (final e in impressions) e.text], ['calm', 'busy']);
    expect(impressions.last.tags, ['crowded']);
    expect(impressions.last.rating, 3);
    expect(
      (await store.entry(diary.id))!.rating,
      isNull,
      reason: 'diary entries carry no rating',
    );
    final counts = (await store.entryCountsByPlace())[kyoto.id]!;
    expect((counts.diary, counts.impressions), (1, 2));
    expect(await store.deletePlace(kyoto.id), isFalse, reason: 'has entries');
  });

  test('links: set in one batch, read for many owners at once', () async {
    final kyoto = await city('Kyoto');
    final a = await store.saveEntry(
      store.newEntry(placeId: kyoto.id, kind: EntryKind.diary),
    );
    final b = await store.saveEntry(
      store.newEntry(placeId: kyoto.id, kind: EntryKind.diary),
    );
    await store.setLinks(LinkOwner.entry, a.id, const [
      TravelLink(LinkTarget.asset, 'photo1'),
      TravelLink(LinkTarget.person, 'mia'),
      TravelLink(LinkTarget.person, 'mia'),
    ]);
    await store.setLinks(LinkOwner.entry, b.id, const [
      TravelLink(LinkTarget.person, 'mia'),
    ]);
    final links = await store.linksFor(LinkOwner.entry, [a.id, b.id, 'none']);
    expect(links[a.id], hasLength(2));
    expect(links[b.id], const [TravelLink(LinkTarget.person, 'mia')]);
    expect(links.containsKey('none'), isFalse);
    expect(await store.entriesLinkedTo(LinkTarget.person, 'mia'), hasLength(2));

    await store.movePerson('mia', 'zoe');
    expect(await store.entriesLinkedTo(LinkTarget.person, 'zoe'), hasLength(2));
    await store.forgetPerson('zoe');
    expect(await store.entriesLinkedTo(LinkTarget.person, 'zoe'), isEmpty);

    await store.deleteEntry(a.id);
    expect(await store.linksFor(LinkOwner.entry, [a.id]), isEmpty);
  });

  group('routes', () {
    late List<Place> stops;
    late TravelRoute route;

    setUp(() async {
      stops = [
        for (final n in ['Tokyo', 'Kyoto', 'Osaka']) await city(n),
      ];
      route = await store.createRoute(
        title: 'Japan',
        starts: DateTime(2025, 11),
      );
      await store.setStops(route.id, [
        for (final s in stops) RouteStop(placeId: s.id),
      ]);
      await store.saveLeg(
        route.id,
        0,
        const RouteLeg(mode: LegMode.train, note: 'shinkansen'),
      );
      await store.saveLeg(
        route.id,
        1,
        const RouteLeg(mode: LegMode.walk, note: 'long walk'),
      );
    });

    test('loads with its stops, legs and places in one go', () async {
      final d = (await store.routeDetail(route.id))!;
      expect(
        [for (final s in d.stops) d.places[s.placeId]!.name],
        ['Tokyo', 'Kyoto', 'Osaka'],
      );
      expect([for (final l in d.legs) l.note], ['shinkansen', 'long walk']);
      expect(d.legs.first.mode, LegMode.train);
      expect((await store.routesThrough(stops[1].id)).single.id, route.id);
    });

    test('outlines: every route\'s stops and flights in one call', () async {
      await store.saveLeg(route.id, 1, const RouteLeg(mode: LegMode.flight));
      final empty = await store.createRoute(title: 'Nowhere yet');
      final outlines = await store.routeOutlines();
      expect(
        [for (final p in outlines[route.id]!.stops) p.name],
        ['Tokyo', 'Kyoto', 'Osaka'],
      );
      expect(outlines[route.id]!.flights, {1});
      expect(outlines[empty.id], isNull);
    });

    test('appending a stop keeps every leg as it was', () async {
      final nara = await city('Nara');
      await store.setStops(route.id, [
        for (final s in [...stops, nara]) RouteStop(placeId: s.id),
      ]);
      final d = (await store.routeDetail(route.id))!;
      expect([for (final l in d.legs) l.note], ['shinkansen', 'long walk', '']);
      expect(d.legs.any((l) => l.needsReview), isFalse);
    });

    test('reordering keeps legs, flagging the ones whose ends moved', () async {
      // Tokyo, Kyoto, Osaka → Kyoto, Osaka, Tokyo.
      await store.setStops(route.id, [
        for (final s in [stops[1], stops[2], stops[0]])
          RouteStop(placeId: s.id),
      ]);
      final d = (await store.routeDetail(route.id))!;
      expect(d.legs[0].note, 'long walk', reason: 'Kyoto→Osaka still adjacent');
      expect(d.legs[0].needsReview, isFalse);
      expect(d.legs[1].note, 'shinkansen');
      expect(d.legs[1].needsReview, isTrue);
    });

    test('removing a stop drops no commentary', () async {
      await store.setStops(route.id, [
        RouteStop(placeId: stops[0].id),
        RouteStop(placeId: stops[2].id),
      ]);
      var d = (await store.routeDetail(route.id))!;
      expect(d.legs.single.note, contains('shinkansen'));
      expect(d.legs.single.note, contains('long walk'));
      expect(d.legs.single.needsReview, isTrue);

      await store.setStops(route.id, [RouteStop(placeId: stops[0].id)]);
      d = (await store.routeDetail(route.id))!;
      expect(d.legs, isEmpty);
      expect(d.route.note, contains('shinkansen'));
    });

    test('deleting a route takes stops, legs and links, not places', () async {
      await store.setLinks(LinkOwner.route, route.id, const [
        TravelLink(LinkTarget.person, 'mia'),
      ]);
      await store.deleteRoute(route.id);
      expect(await store.routeDetail(route.id), isNull);
      expect(await store.routesLinkedTo(LinkTarget.person, 'mia'), isEmpty);
      expect(await store.places(), hasLength(3));
      expect(await store.isPlaceInUse(stops[0].id), isFalse);
    });
  });

  test('every write moves the backup mark, edits included', () async {
    final kyoto = await city('Kyoto');
    final e = await store.saveEntry(
      store.newEntry(placeId: kyoto.id, kind: EntryKind.diary),
    );
    final before = await store.dataMark();
    await store.saveEntry(e.copyWith(text: 'edited'));
    final edited = await store.dataMark();
    expect(edited, isNot(before));
    await store.updatePlace(kyoto.copyWith(name: 'Kyōto'));
    expect(await store.dataMark(), isNot(edited));
  });

  test('rearrangeLegs: a swap of two stops keeps both legs', () {
    const a = RouteLeg(note: 'a');
    const b = RouteLeg(note: 'b');
    final out = rearrangeLegs(['x', 'y', 'z'], [a, b], ['x', 'z', 'y']);
    expect([for (final l in out.legs) l.note], ['a', 'b']);
    expect(out.legs.every((l) => l.needsReview), isTrue);
    expect(out.orphanNotes, isEmpty);
  });
}

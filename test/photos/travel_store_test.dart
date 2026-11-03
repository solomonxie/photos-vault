import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/travel.dart';
import 'package:photos_vault/photos/travel_store.dart';
import 'package:photos_vault/sync/capture.dart';
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

  test('a description is kept, and a version-2 database gains one', () async {
    final kyoto = await city('Kyoto');
    await store.updatePlace(kyoto.copyWith(description: 'East of the river'));
    expect(
      (await store.places()).firstWhere((p) => p.id == kyoto.id).description,
      'East of the river',
    );
    await store.close();

    final old = p.join(dir.path, 'v2.db');
    final db = await databaseFactoryFfi.openDatabase(old);
    await db.execute(
      'CREATE TABLE place (id TEXT PRIMARY KEY, name TEXT NOT NULL, '
      'kind TEXT NOT NULL, lat REAL NOT NULL, lng REAL NOT NULL, '
      "parent_id TEXT, country TEXT NOT NULL DEFAULT '', "
      "address TEXT NOT NULL DEFAULT '', category TEXT NOT NULL DEFAULT '', "
      'created_at INTEGER NOT NULL)',
    );
    await db.insert('place', {
      'id': 'x',
      'name': 'Japan',
      'kind': 'country',
      'lat': 35,
      'lng': 135,
      'created_at': 0,
    });
    await db.execute(
      'CREATE TABLE rev (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)',
    );
    await db.insert('rev', {'id': 1, 'n': 0});
    await db.setVersion(2);
    await db.close();
    store = TravelStore(databaseFactory: databaseFactoryFfi, path: old);
    final upgraded = (await store.places()).single;
    expect(upgraded.description, '');
    await store.updatePlace(upgraded.copyWith(description: 'Home'));
    expect((await store.places()).single.description, 'Home');
  });

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
    // Kyoto, inside Japan, made with it.
    final japan = (await store.places()).singleWhere((p) => p.isCountry);
    expect(kyoto.parentId, japan.id);
    expect(await store.places(), hasLength(3));
    expect(await store.deletePlace(kyoto.id), isFalse, reason: 'has a point');
    expect(await store.deletePlace(shrine.id), isTrue);
  });

  test('impressions under a place, and what Footprints counts', () async {
    final kyoto = await city('Kyoto');
    final gion = await store.createPlace(
      name: 'Gion',
      kind: PlaceKind.area,
      lat: 35,
      lng: 135.77,
      parentId: kyoto.id,
      address: '',
      category: '',
    );
    final cafe = await store.createPlace(
      name: 'Kagizen',
      kind: PlaceKind.point,
      lat: 35,
      lng: 135.77,
      parentId: gion.id,
      address: '264 Gionmachi',
      category: 'Cafe',
    );
    for (final (place, day) in [(cafe, 1), (gion, 2), (cafe, 3)]) {
      await store.saveEntry(
        store
            .newEntry(placeId: place.id, kind: EntryKind.impression)
            .copyWith(at: () => DateTime(2025, 4, day)),
      );
    }
    final tree = placeTree(await store.places());
    final under = await store.entriesAtAny(placeAndBelow(kyoto.id, tree));
    expect(under.map((e) => e.at!.day), [3, 2, 1]);
    expect(await store.entriesAtAny({cafe.id}), hasLength(2));
    expect((await store.place(cafe.id))!.category, 'Cafe');
    expect(await store.counts(), (places: 4, plans: 0));
  });

  test('a version-1 database: its places filed under countries', () async {
    await store.close();
    final path = p.join(dir.path, 'old.db');
    final old = await databaseFactoryFfi.openDatabase(path);
    await old.execute('''
      CREATE TABLE place (id TEXT PRIMARY KEY, name TEXT NOT NULL,
        kind TEXT NOT NULL, lat REAL NOT NULL, lng REAL NOT NULL,
        parent_id TEXT, country TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL)
    ''');
    for (final t in [
      'CREATE TABLE entry (id TEXT PRIMARY KEY, place_id TEXT NOT NULL, '
          "kind TEXT NOT NULL, at INTEGER, title TEXT NOT NULL DEFAULT '', "
          "text TEXT NOT NULL DEFAULT '', rating INTEGER, "
          "tags TEXT NOT NULL DEFAULT '[]', created_at INTEGER NOT NULL, "
          'updated_at INTEGER NOT NULL)',
      'CREATE TABLE route (id TEXT PRIMARY KEY, title TEXT NOT NULL, '
          "note TEXT NOT NULL DEFAULT '', starts INTEGER, ends INTEGER, "
          'created_at INTEGER NOT NULL)',
      'CREATE TABLE stop (route_id TEXT, position INTEGER, place_id TEXT, '
          "arrived INTEGER, note TEXT NOT NULL DEFAULT '')",
      'CREATE TABLE leg (route_id TEXT, position INTEGER, mode TEXT, '
          "note TEXT NOT NULL DEFAULT '', from_place TEXT NOT NULL DEFAULT '', "
          "to_place TEXT NOT NULL DEFAULT '', "
          'needs_review INTEGER NOT NULL DEFAULT 0)',
      'CREATE TABLE link (owner_kind TEXT, owner_id TEXT, target_kind TEXT, '
          'target_id TEXT)',
      'CREATE TABLE rev (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)',
      'INSERT INTO rev VALUES (1, 0)',
    ]) {
      await old.execute(t);
    }
    Future<void> place(String id, String kind, String? parent) =>
        old.insert('place', {
          'id': id,
          'name': id,
          'kind': kind,
          'lat': 35.0,
          'lng': 135.0,
          'parent_id': parent,
          'country': id == 'Lisbon' ? 'Portugal' : 'Japan',
          'created_at': 0,
        });
    await place('Kyoto', 'city', null);
    await place('Shrine', 'point', 'Kyoto');
    await place('Lisbon', 'city', null);
    await old.setVersion(1);
    await old.close();

    store = TravelStore(databaseFactory: databaseFactoryFfi, path: path);
    final places = {for (final p in await store.places()) p.name: p};
    expect(places.keys, containsAll(['Japan', 'Portugal']));
    expect(places['Kyoto']!.parentId, places['Japan']!.id);
    expect(places['Lisbon']!.parentId, places['Portugal']!.id);
    expect(places['Shrine']!.parentId, 'Kyoto');
    expect(places['Shrine']!.address, '');
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
      expect(await store.places(), hasLength(4));
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

  test(
    'a backup merged in brings its rows, never its unsent sync captures',
    () async {
      await setCapture(await store.syncDatabase(), enabled: true);
      await city('Kyoto');
      final copy = p.join(dir.path, 'copy.db');
      expect(await store.copyTo(copy), isTrue);
      final fresh = TravelStore(
        databaseFactory: databaseFactoryFfi,
        path: p.join(dir.path, 'fresh.db'),
      );
      addTearDown(fresh.close);
      expect(await fresh.mergeFrom(copy), greaterThan(0));
      expect((await fresh.places()).map((p) => p.name), contains('Kyoto'));
      expect(await readCaptured(await fresh.syncDatabase()), isEmpty);
    },
  );

  test(
    'an entry saved again is an update, so sync sees only what changed',
    () async {
      await setCapture(await store.syncDatabase(), enabled: true);
      final kyoto = await city('Kyoto');
      final e = await store.saveEntry(
        store.newEntry(placeId: kyoto.id, kind: EntryKind.impression),
      );
      final db = await store.syncDatabase();
      await dropCaptured(db, 1 << 30);
      await store.saveEntry(e.copyWith(text: 'calm'));
      expect(
        [for (final r in await readCaptured(db)) (r.table, r.kind)],
        [('entry', 'update')],
      );
    },
  );
}

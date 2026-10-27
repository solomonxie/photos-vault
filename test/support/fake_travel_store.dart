import 'package:photos_vault/photos/travel.dart';
import 'package:photos_vault/photos/travel_store.dart';

/// In-memory [TravelStore] for widget tests (sqflite can't run inside
/// `testWidgets`' fake async).
class FakeTravelStore implements TravelStore {
  final placesById = <String, Place>{};
  final entriesById = <String, TravelEntry>{};
  final routesById = <String, TravelRoute>{};
  final stopsOf = <String, List<RouteStop>>{};
  final legsOf = <String, List<RouteLeg>>{};
  final links = <(LinkOwner, String), List<TravelLink>>{};
  var _next = 0;
  var _rev = 0;

  @override
  String newId() => 'id${_next++}';

  @override
  Future<void> close() async {}

  @override
  Future<bool> copyTo(String dest) async => false;

  @override
  Future<int> mergeFrom(String path) async => 0;

  @override
  Future<int> dataMark() async => _rev;

  @override
  Future<Place> createPlace({
    required String name,
    required PlaceKind kind,
    required double lat,
    required double lng,
    String? parentId,
    String country = '',
  }) async {
    _rev++;
    final p = Place(
      id: newId(),
      name: name.trim(),
      kind: kind,
      lat: lat,
      lng: lng,
      parentId: parentId,
      country: country,
      createdAt: DateTime(2026),
    );
    return placesById[p.id] = p;
  }

  @override
  Future<void> updatePlace(Place place) async {
    _rev++;
    placesById[place.id] = place;
  }

  @override
  Future<bool> isPlaceInUse(String id) async =>
      entriesById.values.any((e) => e.placeId == id) ||
      stopsOf.values.any((s) => s.any((x) => x.placeId == id)) ||
      placesById.values.any((p) => p.parentId == id);

  @override
  Future<bool> deletePlace(String id) async {
    if (await isPlaceInUse(id)) return false;
    _rev++;
    placesById.remove(id);
    return true;
  }

  int _byName(Place a, Place b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());

  @override
  Future<List<Place>> places() async =>
      placesById.values.toList()..sort(_byName);

  @override
  Future<Place?> place(String id) async => placesById[id];

  @override
  Future<List<Place>> placesIn(String cityId) async => [
    for (final p in placesById.values)
      if (p.parentId == cityId) p,
  ]..sort(_byName);

  @override
  Future<Place> findOrCreateCity({
    required String name,
    String country = '',
    required double lat,
    required double lng,
  }) async {
    for (final p in placesById.values) {
      if (p.isCity &&
          p.name.toLowerCase() == name.trim().toLowerCase() &&
          p.country.toLowerCase() == country.toLowerCase()) {
        return p;
      }
    }
    return createPlace(
      name: name,
      kind: PlaceKind.city,
      lat: lat,
      lng: lng,
      country: country,
    );
  }

  @override
  Future<Map<String, PlaceEntryCounts>> entryCountsByPlace() async {
    final out = <String, PlaceEntryCounts>{};
    for (final e in entriesById.values) {
      final c = out[e.placeId] ?? const PlaceEntryCounts();
      out[e.placeId] = e.kind == EntryKind.diary
          ? PlaceEntryCounts(diary: c.diary + 1, impressions: c.impressions)
          : PlaceEntryCounts(diary: c.diary, impressions: c.impressions + 1);
    }
    return out;
  }

  @override
  TravelEntry newEntry({
    required String placeId,
    required EntryKind kind,
    DateTime? at,
  }) => TravelEntry(
    id: newId(),
    placeId: placeId,
    kind: kind,
    at: at ?? DateTime(2026, 1, 1),
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  @override
  Future<TravelEntry> saveEntry(TravelEntry entry) async {
    _rev++;
    return entriesById[entry.id] = entry;
  }

  @override
  Future<void> deleteEntry(String id) async {
    _rev++;
    entriesById.remove(id);
    links.remove((LinkOwner.entry, id));
  }

  @override
  Future<TravelEntry?> entry(String id) async => entriesById[id];

  static int _newest(TravelEntry a, TravelEntry b) {
    if (a.at == null || b.at == null) {
      return a.at == null ? (b.at == null ? 0 : 1) : -1;
    }
    final byAt = b.at!.compareTo(a.at!);
    return byAt != 0 ? byAt : b.createdAt.compareTo(a.createdAt);
  }

  @override
  Future<List<TravelEntry>> entriesAt(
    String placeId, {
    EntryKind? kind,
  }) async => [
    for (final e in entriesById.values)
      if (e.placeId == placeId && (kind == null || e.kind == kind)) e,
  ]..sort(_newest);

  @override
  Future<List<TravelEntry>> entries({
    EntryKind? kind,
    int limit = 200,
    int offset = 0,
  }) async => ([
    for (final e in entriesById.values)
      if (kind == null || e.kind == kind) e,
  ]..sort(_newest)).skip(offset).take(limit).toList();

  @override
  Future<List<TravelEntry>> entriesLinkedTo(
    LinkTarget target,
    String id,
  ) async => [
    for (final MapEntry(:key, :value) in links.entries)
      if (key.$1 == LinkOwner.entry &&
          value.contains(TravelLink(target, id)) &&
          entriesById[key.$2] != null)
        entriesById[key.$2]!,
  ]..sort(_newest);

  @override
  Future<TravelRoute> createRoute({
    required String title,
    String note = '',
    DateTime? starts,
    DateTime? ends,
  }) async {
    _rev++;
    final r = TravelRoute(
      id: newId(),
      title: title.trim(),
      note: note,
      starts: starts,
      ends: ends,
      createdAt: DateTime(2026),
    );
    return routesById[r.id] = r;
  }

  @override
  Future<void> updateRoute(TravelRoute route) async {
    _rev++;
    routesById[route.id] = route;
  }

  @override
  Future<void> deleteRoute(String id) async {
    _rev++;
    routesById.remove(id);
    stopsOf.remove(id);
    legsOf.remove(id);
    links.remove((LinkOwner.route, id));
  }

  static int _byStart(TravelRoute a, TravelRoute b) {
    if (a.starts == null || b.starts == null) {
      return a.starts == null ? (b.starts == null ? 0 : 1) : -1;
    }
    return b.starts!.compareTo(a.starts!);
  }

  @override
  Future<List<TravelRoute>> routes() async =>
      routesById.values.toList()..sort(_byStart);

  @override
  Future<List<TravelRoute>> routesThrough(String placeId) async => [
    for (final r in routesById.values)
      if ((stopsOf[r.id] ?? const []).any(
        (s) =>
            s.placeId == placeId || placesById[s.placeId]?.parentId == placeId,
      ))
        r,
  ]..sort(_byStart);

  @override
  Future<List<TravelRoute>> routesLinkedTo(
    LinkTarget target,
    String id,
  ) async => [
    for (final MapEntry(:key, :value) in links.entries)
      if (key.$1 == LinkOwner.route &&
          value.contains(TravelLink(target, id)) &&
          routesById[key.$2] != null)
        routesById[key.$2]!,
  ]..sort(_byStart);

  @override
  Future<RouteDetail?> routeDetail(String id) async {
    final route = routesById[id];
    if (route == null) return null;
    final stops = stopsOf[id] ?? const <RouteStop>[];
    final legs = legsOf[id] ?? const <RouteLeg>[];
    return RouteDetail(
      route: route,
      stops: List.of(stops),
      legs: [
        for (var i = 0; i + 1 < stops.length; i++)
          i < legs.length ? legs[i] : const RouteLeg(),
      ],
      places: {
        for (final s in stops)
          if (placesById.containsKey(s.placeId))
            s.placeId: placesById[s.placeId]!,
      },
    );
  }

  @override
  Future<void> setStops(String routeId, List<RouteStop> stops) async {
    _rev++;
    final old = stopsOf[routeId] ?? const <RouteStop>[];
    final oldLegs = legsOf[routeId] ?? const <RouteLeg>[];
    final (:legs, :orphanNotes) = rearrangeLegs(
      [for (final s in old) s.placeId],
      [
        for (var i = 0; i + 1 < old.length; i++)
          i < oldLegs.length ? oldLegs[i] : const RouteLeg(),
      ],
      [for (final s in stops) s.placeId],
    );
    stopsOf[routeId] = List.of(stops);
    legsOf[routeId] = legs;
    final r = routesById[routeId];
    if (orphanNotes.isNotEmpty && r != null) {
      routesById[routeId] = r.copyWith(
        note: [r.note, ...orphanNotes].where((n) => n.isNotEmpty).join('\n\n'),
      );
    }
  }

  @override
  Future<void> saveStop(String routeId, int position, RouteStop stop) async {
    _rev++;
    final stops = stopsOf[routeId];
    if (stops == null || position >= stops.length) return;
    stops[position] = RouteStop(
      placeId: stops[position].placeId,
      arrived: stop.arrived,
      note: stop.note,
    );
  }

  @override
  Future<void> saveLeg(String routeId, int position, RouteLeg leg) async {
    _rev++;
    final stops = stopsOf[routeId] ?? const <RouteStop>[];
    if (position + 1 >= stops.length) return;
    final legs = legsOf[routeId] ??= [];
    while (legs.length < stops.length - 1) {
      legs.add(const RouteLeg());
    }
    legs[position] = leg;
  }

  @override
  Future<void> setLinks(
    LinkOwner owner,
    String ownerId,
    Iterable<TravelLink> links,
  ) async {
    _rev++;
    final list = links.toSet().toList();
    if (list.isEmpty) {
      this.links.remove((owner, ownerId));
    } else {
      this.links[(owner, ownerId)] = list;
    }
  }

  @override
  Future<Map<String, List<TravelLink>>> linksFor(
    LinkOwner owner,
    Iterable<String> ownerIds,
  ) async => {
    for (final id in ownerIds.toSet())
      if (links[(owner, id)] case final l?) id: List.of(l),
  };

  @override
  Future<void> movePerson(String from, String to) async {
    _rev++;
    for (final key in links.keys.toList()) {
      final moved = {
        for (final l in links[key]!)
          l.target == LinkTarget.person && l.id == from
              ? TravelLink(LinkTarget.person, to)
              : l,
      }.toList();
      links[key] = moved;
    }
  }

  @override
  Future<void> forgetPerson(String personId) async {
    _rev++;
    for (final key in links.keys.toList()) {
      links[key] = [
        for (final l in links[key]!)
          if (!(l.target == LinkTarget.person && l.id == personId)) l,
      ];
    }
  }
}

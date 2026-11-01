/// The travel diary's rows (see `docs/design/travel-diary.md`), as
/// `TravelStore` reads and writes them.
///
/// - [Place]: a node in a tree of any depth — a country, its cities, then
///   areas and pins inside them ([Place.parentId]).
/// - [TravelEntry]: an impression (any number per place), or an older
///   diary entry, at a place.
/// - [TravelRoute] with its [RouteStop]s and the [RouteLeg]s between them,
///   loaded together as a [RouteDetail]: a travel plan.
/// - [TravelLink]: a photo or person attached to an entry or route.
library;

/// How big a place is. Any kind may sit inside any bigger one; [area] is
/// anything between a city and a spot (a district, a neighbourhood, a
/// campus), [point] a pin: an exact spot or a business at one.
enum PlaceKind {
  country,
  city,
  area,
  point;

  static PlaceKind of(Object? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => point);

  /// What a place added inside one of these usually is.
  PlaceKind get inside => switch (this) {
    country => city,
    city => area,
    area || point => point,
  };
}

class Place {
  const Place({
    required this.id,
    required this.name,
    required this.kind,
    required this.lat,
    required this.lng,
    this.parentId,
    this.country = '',
    this.address = '',
    this.category = '',
    this.description = '',
    required this.createdAt,
  });

  final String id;
  final String name;
  final PlaceKind kind;
  final double lat;
  final double lng;

  /// The place this one is in; null at the top (a country, or a place not
  /// filed anywhere yet).
  final String? parentId;
  final String country;

  /// A business's street address, when the pin is one.
  final String address;

  /// MapKit's category for a business ("restaurant", "museum").
  final String category;

  /// What the user wrote about it: what the area is, why it matters.
  final String description;
  final DateTime createdAt;

  bool get isCity => kind == PlaceKind.city;
  bool get isCountry => kind == PlaceKind.country;

  Place copyWith({
    String? name,
    PlaceKind? kind,
    double? lat,
    double? lng,
    String? Function()? parentId,
    String? country,
    String? address,
    String? category,
    String? description,
  }) => Place(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    lat: lat ?? this.lat,
    lng: lng ?? this.lng,
    parentId: parentId == null ? this.parentId : parentId(),
    country: country ?? this.country,
    address: address ?? this.address,
    category: category ?? this.category,
    description: description ?? this.description,
    createdAt: createdAt,
  );
}

/// [places] as a tree: children by parent id (null for the top), each
/// list by name.
Map<String?, List<Place>> placeTree(Iterable<Place> places) {
  final byId = {for (final p in places) p.id: p};
  // A place whose parents loop back to it can't be reached from the top.
  bool loops(Place p) {
    final seen = {p.id};
    for (var up = byId[p.parentId]; up != null; up = byId[up.parentId]) {
      if (!seen.add(up.id)) return true;
    }
    return false;
  }

  final out = <String?, List<Place>>{};
  for (final p in places) {
    // A parent that's gone, or a loop, files it at the top, not nowhere.
    final parent = byId.containsKey(p.parentId) && !loops(p)
        ? p.parentId
        : null;
    out.putIfAbsent(parent, () => []).add(p);
  }
  for (final list in out.values) {
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }
  return out;
}

/// [id] and every place under it in [tree].
Set<String> placeAndBelow(String id, Map<String?, List<Place>> tree) {
  final out = <String>{};
  final todo = [id];
  while (todo.isNotEmpty) {
    final next = todo.removeLast();
    if (!out.add(next)) continue;
    todo.addAll([for (final c in tree[next] ?? const <Place>[]) c.id]);
  }
  return out;
}

enum EntryKind {
  diary,
  impression;

  static EntryKind of(Object? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => diary);
}

/// An impression of a place, or a diary entry from before impressions
/// took over. [rating] is for impressions; a diary entry leaves it empty.
class TravelEntry {
  const TravelEntry({
    required this.id,
    required this.placeId,
    required this.kind,
    this.at,
    this.title = '',
    this.text = '',
    this.rating,
    this.tags = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String placeId;
  final EntryKind kind;

  /// The day it's about (the visit), not when it was written.
  final DateTime? at;
  final String title;

  /// Markdown.
  final String text;

  /// 1–5.
  final int? rating;
  final List<String> tags;
  final DateTime createdAt;
  final DateTime updatedAt;

  TravelEntry copyWith({
    String? placeId,
    EntryKind? kind,
    DateTime? Function()? at,
    String? title,
    String? text,
    int? Function()? rating,
    List<String>? tags,
  }) => TravelEntry(
    id: id,
    placeId: placeId ?? this.placeId,
    kind: kind ?? this.kind,
    at: at == null ? this.at : at(),
    title: title ?? this.title,
    text: text ?? this.text,
    rating: rating == null ? this.rating : rating(),
    tags: tags ?? this.tags,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

class TravelRoute {
  const TravelRoute({
    required this.id,
    required this.title,
    this.note = '',
    this.starts,
    this.ends,
    required this.createdAt,
  });

  final String id;
  final String title;

  /// The intro, Markdown.
  final String note;
  final DateTime? starts;
  final DateTime? ends;
  final DateTime createdAt;

  TravelRoute copyWith({
    String? title,
    String? note,
    DateTime? Function()? starts,
    DateTime? Function()? ends,
  }) => TravelRoute(
    id: id,
    title: title ?? this.title,
    note: note ?? this.note,
    starts: starts == null ? this.starts : starts(),
    ends: ends == null ? this.ends : ends(),
    createdAt: createdAt,
  );
}

/// One stop; its position is its index in [RouteDetail.stops].
class RouteStop {
  const RouteStop({required this.placeId, this.arrived, this.note = ''});

  final String placeId;
  final DateTime? arrived;

  /// What happened here.
  final String note;

  RouteStop copyWith({DateTime? Function()? arrived, String? note}) =>
      RouteStop(
        placeId: placeId,
        arrived: arrived == null ? this.arrived : arrived(),
        note: note ?? this.note,
      );
}

enum LegMode {
  walk,
  drive,
  train,
  flight,
  boat,
  other;

  static LegMode of(Object? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => other);
}

/// The way from stop `i` to stop `i + 1`: [RouteDetail.legs][i].
class RouteLeg {
  const RouteLeg({
    this.mode = LegMode.other,
    this.note = '',
    this.needsReview = false,
  });

  final LegMode mode;
  final String note;

  /// The stops either side changed since this was written (a reorder or a
  /// removal): kept, but worth a second look.
  final bool needsReview;

  RouteLeg copyWith({LegMode? mode, String? note, bool? needsReview}) =>
      RouteLeg(
        mode: mode ?? this.mode,
        note: note ?? this.note,
        needsReview: needsReview ?? this.needsReview,
      );
}

/// A route with everything its page draws, from one load.
class RouteDetail {
  const RouteDetail({
    required this.route,
    required this.stops,
    required this.legs,
    required this.places,
  });

  final TravelRoute route;
  final List<RouteStop> stops;

  /// `stops.length - 1` of them (none for fewer than two stops).
  final List<RouteLeg> legs;

  /// Every stop's place, by id.
  final Map<String, Place> places;
}

/// A route's stops in order and which legs are flights: what a list card
/// draws.
class RouteOutline {
  const RouteOutline({this.stops = const [], this.flights = const {}});

  final List<Place> stops;

  /// Leg positions flown.
  final Set<int> flights;
}

enum LinkOwner { entry, route }

enum LinkTarget {
  asset,
  person;

  static LinkTarget of(Object? name) =>
      values.firstWhere((v) => v.name == name, orElse: () => asset);
}

/// A photo (`AssetRecord.localId`) or a person (`Person.id`).
class TravelLink {
  const TravelLink(this.target, this.id);

  final LinkTarget target;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is TravelLink && other.target == target && other.id == id;

  @override
  int get hashCode => Object.hash(target, id);

  @override
  String toString() => '${target.name}:$id';
}

/// Entries at one place, by kind.
class PlaceEntryCounts {
  const PlaceEntryCounts({this.diary = 0, this.impressions = 0});

  final int diary;
  final int impressions;

  int get total => diary + impressions;
}

/// Legs for [next] stops, rearranged from [legs] between [previous] stops.
///
/// A leg whose two places are still side by side, in the same order, keeps
/// its place and stays as it was. Every other new gap takes the unused old
/// legs in their old order, flagged [RouteLeg.needsReview]. Old legs left
/// over (stops were removed) have their notes appended to the nearest
/// flagged leg, so nothing written is dropped; with no legs left at all,
/// they come back in [orphanNotes].
({List<RouteLeg> legs, List<String> orphanNotes}) rearrangeLegs(
  List<String> previous,
  List<RouteLeg> legs,
  List<String> next,
) {
  final gaps = next.length < 2 ? 0 : next.length - 1;
  final used = <int>{};
  final out = List<RouteLeg?>.filled(gaps, null);
  for (var i = 0; i < gaps; i++) {
    for (var j = 0; j < legs.length && j + 1 < previous.length; j++) {
      if (used.contains(j)) continue;
      if (previous[j] == next[i] && previous[j + 1] == next[i + 1]) {
        out[i] = legs[j];
        used.add(j);
        break;
      }
    }
  }
  final spare = [
    for (var j = 0; j < legs.length; j++)
      if (!used.contains(j)) legs[j],
  ];
  var s = 0;
  for (var i = 0; i < gaps; i++) {
    if (out[i] != null) continue;
    out[i] = s < spare.length
        ? spare[s++].copyWith(needsReview: true)
        : const RouteLeg();
  }
  final left = [
    for (; s < spare.length; s++)
      if (spare[s].note.trim().isNotEmpty) spare[s].note,
  ];
  final result = out.cast<RouteLeg>();
  if (left.isEmpty) return (legs: result, orphanNotes: const []);
  if (result.isEmpty) return (legs: result, orphanNotes: left);
  final at = result.lastIndexWhere((l) => l.needsReview);
  final i = at < 0 ? result.length - 1 : at;
  result[i] = result[i].copyWith(
    note: [result[i].note, ...left].where((n) => n.isNotEmpty).join('\n\n'),
    needsReview: true,
  );
  return (legs: result, orphanNotes: const []);
}

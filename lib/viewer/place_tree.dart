import '../photos/travel.dart';
import '../storage/asset_record.dart';

enum PlaceLevel { country, city, pin }

/// One row of Places: a country or city from the photos' own location
/// names, or a pin made by hand. Pins sit under their city; an area made
/// before pins replaced them is shown as a pin.
class PlaceNode {
  PlaceNode(this.level, this.name, {this.place});

  final PlaceLevel level;
  final String name;

  /// The saved place behind the row: always for a pin; for a country or
  /// city once it has been saved in Footprints (its page holds the notes).
  Place? place;
  final records = <AssetRecord>[];
  final children = <PlaceNode>[];

  /// This node and everything under it, depth first.
  Iterable<(PlaceNode, int)> walk([int depth = 0]) sync* {
    yield (this, depth);
    for (final c in children) {
      yield* c.walk(depth + 1);
    }
  }
}

/// "Melbourne, Australia" → (Australia, Melbourne); "Australia" → (Australia, '').
(String, String)? _countryCity(String location) {
  final parts = [
    for (final p in location.split(','))
      if (p.trim().isNotEmpty) p.trim(),
  ];
  if (parts.isEmpty) return null;
  return (parts.last, parts.length > 1 ? parts[parts.length - 2] : '');
}

/// Country → city from [groups] (photos by place name, as the library
/// grouped them), with [places]' pins filed under their city by name.
/// Biggest first; pins after cities.
List<PlaceNode> buildPlaceTree(
  Map<String, List<AssetRecord>> groups,
  List<Place> places,
) {
  final countries = <String, PlaceNode>{};
  final cities = <String, PlaceNode>{};
  PlaceNode country(String name) => countries.putIfAbsent(
    name.toLowerCase(),
    () => PlaceNode(PlaceLevel.country, name),
  );
  PlaceNode city(PlaceNode parent, String name) => cities.putIfAbsent(
    '${parent.name.toLowerCase()}|${name.toLowerCase()}',
    () {
      final node = PlaceNode(PlaceLevel.city, name);
      parent.children.add(node);
      return node;
    },
  );

  for (final MapEntry(:key, :value) in groups.entries) {
    final at = _countryCity(key);
    if (at == null) continue;
    final c = country(at.$1)..records.addAll(value);
    if (at.$2.isNotEmpty) city(c, at.$2).records.addAll(value);
  }

  final byId = {for (final p in places) p.id: p};
  String countryOf(Place p) {
    final seen = <String>{};
    for (var up = byId[p.parentId]; up != null; up = byId[up.parentId]) {
      if (!seen.add(up.id)) break;
      if (up.kind == PlaceKind.country) return up.name;
    }
    return p.country;
  }

  // Saved countries and cities: shown even with no photos, and their rows
  // open their own page.
  for (final p in places) {
    if (p.kind == PlaceKind.country) {
      country(p.name).place ??= p;
    } else if (p.kind == PlaceKind.city) {
      final name = countryOf(p);
      if (name.isEmpty) continue;
      city(country(name), p.name).place ??= p;
    }
  }

  for (final p in places) {
    if (p.kind != PlaceKind.point && p.kind != PlaceKind.area) continue;
    Place? cityPlace;
    Place? countryPlace;
    final seen = <String>{};
    for (var up = byId[p.parentId]; up != null; up = byId[up.parentId]) {
      if (!seen.add(up.id)) break;
      if (up.kind == PlaceKind.city) cityPlace ??= up;
      if (up.kind == PlaceKind.country) countryPlace ??= up;
    }
    final countryName = countryPlace?.name ?? p.country;
    if (countryName.isEmpty) continue;
    final c = country(countryName);
    final parent = cityPlace == null ? c : city(c, cityPlace.name);
    parent.children.add(PlaceNode(PlaceLevel.pin, p.name, place: p));
  }

  void sort(List<PlaceNode> list) {
    list.sort((a, b) {
      final pin =
          (a.level == PlaceLevel.pin ? 1 : 0) -
          (b.level == PlaceLevel.pin ? 1 : 0);
      if (pin != 0) return pin;
      final n = b.records.length - a.records.length;
      return n != 0 ? n : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    for (final c in list) {
      sort(c.children);
    }
  }

  final top = countries.values.toList();
  sort(top);
  return top;
}

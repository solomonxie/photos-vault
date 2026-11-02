import 'dart:math' as math;

import '../storage/asset_record.dart';
import 'travel.dart';

/// One stop of a plan drafted from photos: a saved pin the photos were
/// taken at, else the city they were filed under (made on save when
/// [placeId] is null).
class DraftStop {
  const DraftStop({
    required this.placeId,
    required this.name,
    required this.country,
    required this.lat,
    required this.lng,
    required this.arrived,
    required this.photos,
  });

  final String? placeId;
  final String name;
  final String country;
  final double lat;
  final double lng;
  final DateTime arrived;

  /// The photos it stands for, first taken first.
  final List<AssetRecord> photos;

  String get key => placeId ?? '${name.toLowerCase()}|${country.toLowerCase()}';
}

/// Fewer photos than this in a row somewhere is passing through, not a stop.
const draftMinPhotos = 3;

/// [records] (oldest first, as `listAll` keeps them) taken from [from] to
/// [to], both days included, as stops in time order. A run of photos at
/// the same spot is one stop, however many days it spans; a run too short
/// to be a stop is dropped, and the runs either side of it join when they
/// are the same spot.
List<DraftStop> draftStops(
  List<AssetRecord> records,
  DateTime from,
  DateTime to,
  List<Place> places,
) {
  final start = DateTime(from.year, from.month, from.day);
  final end = DateTime(to.year, to.month, to.day).add(const Duration(days: 1));
  final pins = [
    for (final p in places)
      if (p.kind == PlaceKind.point || p.kind == PlaceKind.area) p,
  ];
  final cities = {
    for (final p in places)
      if (p.kind == PlaceKind.city)
        '${p.name.toLowerCase()}|${p.country.toLowerCase()}': p,
  };
  var lo = 0;
  var hi = records.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (records[mid].createdAt.isBefore(start)) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final runs = <DraftStop>[];
  for (var i = lo; i < records.length; i++) {
    final r = records[i];
    if (!r.createdAt.isBefore(end)) break;
    if (r.passcodeHash != null || r.deletedAt != null) continue;
    final spot = _spotOf(r, pins, cities);
    if (spot == null) continue;
    final last = runs.isEmpty ? null : runs.last;
    if (last != null && last.key == spot.key) {
      last.photos.add(r);
    } else {
      runs.add(spot);
    }
  }
  final kept = runs.where((s) => s.photos.length >= draftMinPhotos).toList();
  final list = kept.isEmpty ? runs : kept;
  final out = <DraftStop>[];
  for (final s in list) {
    if (out.isNotEmpty && out.last.key == s.key) {
      out.last.photos.addAll(s.photos);
    } else {
      out.add(s);
    }
  }
  return out;
}

DraftStop? _spotOf(AssetRecord r, List<Place> pins, Map<String, Place> cities) {
  if ((r.latitude, r.longitude) case (final la?, final lo?)) {
    Place? best;
    var bestD = double.infinity;
    for (final p in pins) {
      final d = _metres(la, lo, p.lat, p.lng);
      if (d < (p.kind == PlaceKind.area ? 1500 : 300) && d < bestD) {
        best = p;
        bestD = d;
      }
    }
    if (best != null) return _stop(best.id, best.name, best.country, best, r);
  }
  final parts = [
    for (final s in (r.location ?? '').split(','))
      if (s.trim().isNotEmpty) s.trim(),
  ];
  if (parts.length < 2) return null;
  final name = parts[parts.length - 2];
  final country = parts.last;
  final saved = cities['${name.toLowerCase()}|${country.toLowerCase()}'];
  return _stop(saved?.id, saved?.name ?? name, country, saved, r);
}

DraftStop _stop(
  String? id,
  String name,
  String country,
  Place? place,
  AssetRecord r,
) => DraftStop(
  placeId: id,
  name: name,
  country: country,
  lat: place?.lat ?? r.latitude ?? 0,
  lng: place?.lng ?? r.longitude ?? 0,
  arrived: r.createdAt,
  photos: [r],
);

double _metres(double lat1, double lng1, double lat2, double lng2) {
  const metresPerDegree = 111320.0;
  final dy = (lat1 - lat2) * metresPerDegree;
  final dx = (lng1 - lng2) * metresPerDegree * math.cos(lat2 * math.pi / 180);
  return math.sqrt(dx * dx + dy * dy);
}

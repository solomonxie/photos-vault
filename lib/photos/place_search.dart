import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart' as geo;

/// Finding places for the travel diary, through MapKit on the phone
/// (`ios/Runner/MapChannel.swift`, channel `byo.photos/places`):
///
/// - [search]: cities and points by name (`MKLocalSearch`).
/// - [snapshot]: a still map for a list row, cached as a JPEG.
/// - [cityAt]: the town a coordinate is in (the OS geocoder), so a new
///   point can find its city.
///
/// Every call answers empty rather than throwing when the native side is
/// missing (tests, a platform without it).
class PlaceSearch {
  PlaceSearch({
    MethodChannel? channel,
    Future<List<geo.Placemark>> Function(double lat, double lng)?
    reverseGeocode,
  }) : _channel = channel ?? const MethodChannel('byo.photos/places'),
       _reverse = reverseGeocode ?? geo.placemarkFromCoordinates;

  final MethodChannel _channel;
  final Future<List<geo.Placemark>> Function(double lat, double lng) _reverse;

  /// Up to 20 matches for [query], nearest [near] first when given.
  Future<List<PlaceResult>> search(
    String query, {
    (double, double)? near,
  }) async {
    if (query.trim().isEmpty) return const [];
    try {
      final rows = await _channel.invokeListMethod<Object?>('search', {
        'query': query,
        if (near != null) 'lat': near.$1,
        if (near != null) 'lng': near.$2,
      });
      return [for (final r in rows ?? const []) ?PlaceResult.fromMap(r)];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// A [width]×[height] point map with [pins] (and [line] through them),
  /// as a cached JPEG's path; null when it couldn't be drawn.
  Future<String?> snapshot({
    required List<MapPinData> pins,
    MapLineData? line,
    double width = 300,
    double height = 160,
  }) async {
    if (pins.isEmpty) return null;
    try {
      return await _channel.invokeMethod<String>('snapshot', {
        'pins': [for (final p in pins) p.toMap()],
        if (line != null) 'line': line.toMap(),
        'width': width,
        'height': height,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// The city at a coordinate, as (name, country); null when the geocoder
  /// has no town there or refuses (it's rate-limited).
  Future<(String, String)?> cityAt(double lat, double lng) async {
    try {
      final marks = await _reverse(lat, lng);
      for (final m in marks) {
        final name = [m.locality, m.subAdministrativeArea, m.administrativeArea]
            .firstWhere(
              (n) => n != null && n.trim().isNotEmpty,
              orElse: () => null,
            );
        if (name != null) return (name.trim(), m.country?.trim() ?? '');
      }
    } catch (_) {
      // No network, throttled, or no plugin: the point stays unplaced.
    }
    return null;
  }
}

class PlaceResult {
  const PlaceResult({
    required this.name,
    required this.locality,
    required this.country,
    required this.lat,
    required this.lng,
    required this.isCity,
  });

  final String name;

  /// The town it's in (for a city, usually its own name).
  final String locality;
  final String country;
  final double lat;
  final double lng;

  /// A town on its own rather than an address or a business in one.
  final bool isCity;

  static PlaceResult? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final lat = raw['lat'];
    final lng = raw['lng'];
    final name = raw['name'];
    if (lat is! num || lng is! num || name is! String || name.isEmpty) {
      return null;
    }
    return PlaceResult(
      name: name,
      locality: raw['locality'] as String? ?? '',
      country: raw['country'] as String? ?? '',
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      isCity: raw['isCity'] == true,
    );
  }
}

/// A pin on a map: [number] is drawn in it (a route's stop order).
class MapPinData {
  const MapPinData({
    required this.id,
    required this.lat,
    required this.lng,
    this.title = '',
    this.number,
  });

  final String id;
  final double lat;
  final double lng;
  final String title;
  final int? number;

  Map<String, Object?> toMap() => {
    'id': id,
    'lat': lat,
    'lng': lng,
    'title': title,
    if (number != null) 'number': number,
  };

  @override
  bool operator ==(Object other) =>
      other is MapPinData &&
      other.id == id &&
      other.lat == lat &&
      other.lng == lng &&
      other.title == title &&
      other.number == number;

  @override
  int get hashCode => Object.hash(id, lat, lng, title, number);
}

/// A line through [points]; [geodesic] per segment draws it as a great
/// circle (a flight).
class MapLineData {
  const MapLineData(this.points, {this.geodesic = const []});

  final List<(double, double)> points;
  final List<bool> geodesic;

  Map<String, Object?> toMap() => {
    'points': [
      for (final (lat, lng) in points) [lat, lng],
    ],
    'geodesic': geodesic,
  };

  @override
  bool operator ==(Object other) =>
      other is MapLineData &&
      listEquals(other.points, points) &&
      listEquals(other.geodesic, geodesic);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(points), Object.hashAll(geodesic));
}

import 'package:geocoding/geocoding.dart' as geo;
import 'package:photo_manager/photo_manager.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'photo_library_service.dart';

/// Turns the GPS tag a camera writes into a place name, so Places fills
/// itself in instead of waiting for someone to type "Melbourne" a thousand
/// times.
///
/// Reverse geocoding goes through the OS geocoder (`CLGeocoder` on iOS),
/// which is rate-limited per app and starts refusing after a burst — so
/// the thing to avoid isn't asking in bulk, it's *asking the same question
/// twice*. Answers are cached per rounded-off patch of the world
/// ([cellFor]), which is the right grain for an answer like "Melbourne,
/// Australia": a day out, a holiday, a whole childhood in one town all
/// collapse to one lookup. What's left is one question per place the user
/// has ever been, and [fillMissing] spends those slowly in the background
/// while the scan works through the library.
///
/// Only fills an empty [AssetRecord.location] — a name the user typed is
/// theirs, and is never overwritten by a guess.
class PhotoLocationService {
  PhotoLocationService({
    Future<LatLng?> Function(AssetRecord record)? coordinatesOf,
    Future<List<geo.Placemark>> Function(double latitude, double longitude)?
    reverseGeocode,
  }) : _coordinatesOf = coordinatesOf ?? _defaultCoordinatesOf,
       _reverseGeocode = reverseGeocode ?? geo.placemarkFromCoordinates;

  final Future<LatLng?> Function(AssetRecord record) _coordinatesOf;
  final Future<List<geo.Placemark>> Function(double latitude, double longitude)
  _reverseGeocode;

  /// Roughly 5km of the world per cache cell. Chosen against what's being
  /// cached rather than against precision: the answer is a town's name, and
  /// two photos 5km apart are almost always in the same town. Too fine and
  /// a walk across a city is twenty lookups; too coarse and a village
  /// inherits the name of the city next door.
  static const cellSize = 0.05;

  /// How long to leave between lookups. The geocoder is a shared, throttled
  /// OS service — this is a background job filling in photos nobody has
  /// asked about yet, so it should never be the reason a lookup the user
  /// *is* waiting for comes back refused.
  static const spacing = Duration(milliseconds: 600);

  /// Which cache cell a coordinate falls in. Floor, not round, so the cell
  /// a coordinate belongs to never depends on which side of it you came
  /// from.
  static String cellFor(double latitude, double longitude) {
    final lat = (latitude / cellSize).floor();
    final lng = (longitude / cellSize).floor();
    return '$lat:$lng';
  }

  /// Names the places of photos the scan has found coordinates for but
  /// nobody has named yet, and writes them into [store]. Returns how many
  /// photos got a name.
  ///
  /// Stops early on [limit] photos so a first run over a decade of photos
  /// doesn't hold the geocoder all afternoon — the next run continues, and
  /// each run is cheaper than the last as the cache fills.
  Future<int> fillMissing(
    AssetRecordStore store, {
    int limit = 500,
    Future<void> Function(Duration) wait = Future.delayed,
  }) async {
    final pending = await store.listAwaitingPlaceName(limit: limit);
    var named = 0;
    for (final record in pending) {
      final latitude = record.latitude;
      final longitude = record.longitude;
      if (latitude == null || longitude == null) continue;
      final cell = cellFor(latitude, longitude);
      var cached = await store.cachedPlaceName(cell);
      if (cached == null) {
        // Only an unknown cell costs a question, and the pause goes with
        // the question rather than with the photo.
        final name = await _lookUp(latitude, longitude);
        await store.cachePlaceName(cell, name);
        cached = PlaceNameEntry(name);
        await wait(spacing);
      }
      final name = cached.name;
      if (name == null || name.isEmpty) continue;
      // Re-read: the user may have typed one while this was working.
      final current = await store.getByLocalId(record.localId);
      final existing = current?.location;
      if (current == null || (existing != null && existing.isNotEmpty)) {
        continue;
      }
      await store.setLocation(record.localId, name);
      named++;
    }
    return named;
  }

  Future<String?> _lookUp(double latitude, double longitude) async {
    try {
      final placemarks = await _reverseGeocode(latitude, longitude);
      if (placemarks.isEmpty) return null;
      return placeNameOf(placemarks.first);
    } catch (_) {
      return null;
    }
  }

  /// Camera-roll assets only. A manually-added file's EXIF isn't read here:
  /// the OS already parsed it for everything in the photo library, and a
  /// second, hand-rolled EXIF path for the handful of imported files would
  /// be the only place this app parses tags itself.
  static Future<LatLng?> _defaultCoordinatesOf(AssetRecord record) async {
    if (record.sourceType != AssetSourceType.photoManager) return null;
    final id = PhotoLibraryService.libraryIdOf(record);
    if (id == null) return null;
    final entity = await AssetEntity.fromId(id);
    if (entity == null) return null;
    final latLng = entity.latLng ?? await entity.latlngAsync();
    if (latLng == null) return null;
    // A photo with no location tag reads back as 0,0 rather than null —
    // and Null Island is nobody's holiday.
    if (latLng.latitude == 0 && latLng.longitude == 0) return null;
    return latLng;
  }

  /// The place name for [record], or `null` if it has no GPS tag, the
  /// geocoder has nothing for those coordinates, or it's rate-limited.
  ///
  /// [store], when given, is both where the answer is cached and where a
  /// previous answer for the same patch of the world comes from — which is
  /// usually, since the photo being opened is generally near others.
  Future<String?> placeNameFor(
    AssetRecord record, {
    AssetRecordStore? store,
  }) async {
    try {
      final latLng = record.hasCoordinates
          ? LatLng(latitude: record.latitude!, longitude: record.longitude!)
          : await _coordinatesOf(record);
      if (latLng == null) return null;
      final cell = cellFor(latLng.latitude, latLng.longitude);
      final cached = await store?.cachedPlaceName(cell);
      if (cached != null) return cached.name;
      final name = await _lookUp(latLng.latitude, latLng.longitude);
      await store?.cachePlaceName(cell, name);
      return name;
    } catch (_) {
      // No plugin (tests), no network, or the geocoder is throttling —
      // the field just stays empty and can be typed in by hand.
      return null;
    }
  }

  /// How a placemark reads as one line: the most specific human-scale name
  /// available, and the country after it when that isn't already implied.
  /// "Melbourne, Australia", not "Greater Melbourne, Victoria, Australia,
  /// 3000".
  static String? placeNameOf(geo.Placemark placemark) {
    final local = [
      placemark.locality,
      placemark.subAdministrativeArea,
      placemark.administrativeArea,
    ].firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    final country = placemark.country;
    if (local == null || local.isEmpty) {
      return (country == null || country.isEmpty) ? null : country;
    }
    if (country == null || country.isEmpty || country == local) return local;
    return '$local, $country';
  }
}

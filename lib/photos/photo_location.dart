import 'package:geocoding/geocoding.dart' as geo;
import 'package:photo_manager/photo_manager.dart';

import '../storage/asset_record.dart';
import 'photo_library_service.dart';

/// Turns the GPS tag a camera writes into a place name, so Places fills
/// itself in instead of waiting for someone to type "Melbourne" a thousand
/// times.
///
/// Resolved **on view, one photo at a time** rather than swept over the
/// whole library: reverse geocoding goes through the OS geocoder
/// (`CLGeocoder` on iOS), which is rate-limited per app and starts refusing
/// after a burst. A background pass over a decade of photos would spend its
/// whole budget on photos nobody is looking at.
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

  /// Camera-roll assets only. A manually-added file's EXIF isn't read here:
  /// the OS already parsed it for everything in the photo library, and a
  /// second, hand-rolled EXIF path for the handful of imported files would
  /// be the only place this app parses tags itself.
  static Future<LatLng?> _defaultCoordinatesOf(AssetRecord record) async {
    if (record.sourceType != AssetSourceType.photoManager) return null;
    final id = PhotoLibraryService.entityIdFrom(record.localId);
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
  Future<String?> placeNameFor(AssetRecord record) async {
    try {
      final latLng = await _coordinatesOf(record);
      if (latLng == null) return null;
      final placemarks = await _reverseGeocode(
        latLng.latitude,
        latLng.longitude,
      );
      if (placemarks.isEmpty) return null;
      return placeNameOf(placemarks.first);
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

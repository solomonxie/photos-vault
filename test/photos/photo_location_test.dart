import 'package:bring_your_own_photos/photos/photo_location.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:photo_manager/photo_manager.dart';

AssetRecord _record({String? location}) => AssetRecord(
  localId: 'photo:1',
  contentHash: '1',
  platform: 'ios',
  createdAt: DateTime(2024, 5, 4),
  updatedAt: DateTime(2024, 5, 4),
  location: location,
);

geo.Placemark _placemark({
  String? locality,
  String? subAdministrativeArea,
  String? administrativeArea,
  String? country,
}) => geo.Placemark(
  locality: locality,
  subAdministrativeArea: subAdministrativeArea,
  administrativeArea: administrativeArea,
  country: country,
);

void main() {
  group('placeNameOf', () {
    test('reads as "city, country"', () {
      expect(
        PhotoLocationService.placeNameOf(
          _placemark(
            locality: 'Melbourne',
            administrativeArea: 'Victoria',
            country: 'Australia',
          ),
        ),
        'Melbourne, Australia',
      );
    });

    test('falls back through the administrative ladder for a photo in the middle of nowhere', () {
      expect(
        PhotoLocationService.placeNameOf(
          _placemark(
            locality: '',
            subAdministrativeArea: 'Kangaroo Island',
            country: 'Australia',
          ),
        ),
        'Kangaroo Island, Australia',
      );
    });

    test('country alone when that is all there is', () {
      expect(
        PhotoLocationService.placeNameOf(_placemark(country: 'Iceland')),
        'Iceland',
      );
    });

    test('a city-state is not repeated', () {
      expect(
        PhotoLocationService.placeNameOf(
          _placemark(locality: 'Singapore', country: 'Singapore'),
        ),
        'Singapore',
      );
    });

    test('nothing at all reads as no place', () {
      expect(PhotoLocationService.placeNameOf(_placemark()), isNull);
    });
  });

  group('placeNameFor', () {
    test('geocodes the photo\'s own coordinates', () async {
      double? geocodedLat;
      final service = PhotoLocationService(
        coordinatesOf: (_) async =>
            const LatLng(latitude: 48.86, longitude: 2.35),
        reverseGeocode: (lat, lng) async {
          geocodedLat = lat;
          return [_placemark(locality: 'Paris', country: 'France')];
        },
      );

      expect(await service.placeNameFor(_record()), 'Paris, France');
      expect(geocodedLat, 48.86);
    });

    test('an untagged photo is left alone, and never geocoded', () async {
      var geocoded = false;
      final service = PhotoLocationService(
        coordinatesOf: (_) async => null,
        reverseGeocode: (lat, lng) async {
          geocoded = true;
          return const [];
        },
      );

      expect(await service.placeNameFor(_record()), isNull);
      expect(geocoded, isFalse);
    });

    test(
      'a throttled or offline geocoder yields no name rather than throwing',
      () async {
        final service = PhotoLocationService(
          coordinatesOf: (_) async => const LatLng(latitude: 1, longitude: 2),
          reverseGeocode: (lat, lng) async => throw Exception('rate limited'),
        );

        expect(await service.placeNameFor(_record()), isNull);
      },
    );

    test('no placemark for those coordinates yields no name', () async {
      final service = PhotoLocationService(
        coordinatesOf: (_) async => const LatLng(latitude: 1, longitude: 2),
        reverseGeocode: (lat, lng) async => const [],
      );

      expect(await service.placeNameFor(_record()), isNull);
    });
  });
}

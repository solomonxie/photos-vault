import 'package:photos_vault/photos/photo_location.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:photo_manager/photo_manager.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AssetRecord _record({String? location}) => AssetRecord(
  localId: 'photo:1',
  contentHash: '1',
  platform: 'ios',
  createdAt: DateTime(2024, 5, 4),
  updatedAt: DateTime(2024, 5, 4),
  location: location,
);

/// The store is opened in-memory rather than faked: the cache table and
/// the "which photos still need a name" query are half of what's being
/// tested here.
AssetRecordStore _newStore() => AssetRecordStore(
  databaseFactory: databaseFactoryFfi,
  path: inMemoryDatabasePath,
);

Future<void> _addTagged(
  AssetRecordStore store,
  String id, {
  required double latitude,
  required double longitude,
  String? location,
}) async {
  await store.upsert(
    localId: id,
    contentHash: id,
    platform: 'ios',
    latitude: latitude,
    longitude: longitude,
  );
  if (location != null) await store.setLocation(id, location);
}

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

  group('fillMissing', () {
    setUpAll(sqfliteFfiInit);

    test(
      'names every photo the scan tagged, and only asks once per place',
      () async {
        final store = _newStore();
        addTearDown(store.close);
        // Three photos from one afternoon in one city, one from another
        // continent.
        await _addTagged(store, 'a', latitude: 48.8601, longitude: 2.3502);
        await _addTagged(store, 'b', latitude: 48.8612, longitude: 2.3521);
        await _addTagged(store, 'c', latitude: 48.8607, longitude: 2.3544);
        await _addTagged(store, 'd', latitude: -37.8136, longitude: 144.9631);
        var lookups = 0;
        final service = PhotoLocationService(
          reverseGeocode: (lat, lng) async {
            lookups++;
            return [
              lat > 0
                  ? _placemark(locality: 'Paris', country: 'France')
                  : _placemark(locality: 'Melbourne', country: 'Australia'),
            ];
          },
        );

        final named = await service.fillMissing(store, wait: (_) async {});

        expect(named, 4);
        expect(lookups, 2, reason: 'one per place, not one per photo');
        expect((await store.getByLocalId('b'))!.location, 'Paris, France');
        expect(
          (await store.getByLocalId('d'))!.location,
          'Melbourne, Australia',
        );
      },
    );

    test('a name somebody typed is never overwritten by a guess', () async {
      final store = _newStore();
      addTearDown(store.close);
      await _addTagged(
        store,
        'a',
        latitude: 48.86,
        longitude: 2.35,
        location: 'Our flat',
      );
      final service = PhotoLocationService(
        reverseGeocode: (lat, lng) async => [
          _placemark(locality: 'Paris', country: 'France'),
        ],
      );

      expect(await service.fillMissing(store, wait: (_) async {}), 0);
      expect((await store.getByLocalId('a'))!.location, 'Our flat');
    });

    test(
      'a place the geocoder has nothing for is not asked about twice',
      () async {
        final store = _newStore();
        addTearDown(store.close);
        await _addTagged(store, 'a', latitude: 10, longitude: 20);
        await _addTagged(store, 'b', latitude: 10.001, longitude: 20.001);
        var lookups = 0;
        final service = PhotoLocationService(
          reverseGeocode: (lat, lng) async {
            lookups++;
            return const [];
          },
        );

        await service.fillMissing(store, wait: (_) async {});
        await service.fillMissing(store, wait: (_) async {});

        expect(lookups, 1);
        expect((await store.getByLocalId('a'))!.location, isNull);
      },
    );

    test('an untagged photo is not waiting for a name at all', () async {
      final store = _newStore();
      addTearDown(store.close);
      await store.upsert(localId: 'a', contentHash: 'a', platform: 'ios');
      var lookups = 0;
      final service = PhotoLocationService(
        reverseGeocode: (lat, lng) async {
          lookups++;
          return const [];
        },
      );

      expect(await service.fillMissing(store, wait: (_) async {}), 0);
      expect(lookups, 0);
    });
  });

  group('cellFor', () {
    test('neighbours share a cell, distant places do not', () {
      expect(
        PhotoLocationService.cellFor(48.8600, 2.3500),
        PhotoLocationService.cellFor(48.8612, 2.3521),
      );
      expect(
        PhotoLocationService.cellFor(48.86, 2.35),
        isNot(PhotoLocationService.cellFor(-37.81, 144.96)),
      );
    });

    test(
      'a cell is the patch a coordinate is in, not the one it is nearest',
      () {
        // Either side of a cell boundary, however close together.
        expect(
          PhotoLocationService.cellFor(0.0499, 0),
          isNot(PhotoLocationService.cellFor(0.0501, 0)),
        );
      },
    );
  });
}

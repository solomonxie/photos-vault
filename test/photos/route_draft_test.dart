import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/route_draft.dart';
import 'package:photos_vault/photos/travel.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/footprints_screens.dart';
import 'package:photos_vault/viewer/place_screen.dart';

AssetRecord _at(
  String id,
  DateTime t, {
  String? location,
  double? lat,
  double? lng,
  bool hidden = false,
}) => AssetRecord(
  localId: id,
  contentHash: id,
  platform: 'ios',
  createdAt: t,
  updatedAt: t,
  sourceType: AssetSourceType.manualFile,
  sourcePath: '/tmp/$id.jpg',
  location: location,
  latitude: lat,
  longitude: lng,
  passcodeHash: hidden ? 'h' : null,
);

Place _place(
  String id,
  String name,
  PlaceKind kind, {
  double lat = 0,
  double lng = 0,
}) => Place(
  id: id,
  name: name,
  kind: kind,
  lat: lat,
  lng: lng,
  country: 'Japan',
  createdAt: DateTime(2020),
);

List<AssetRecord> _run(
  String prefix,
  DateTime from,
  int n, {
  String? location,
  double? lat,
  double? lng,
}) => [
  for (var i = 0; i < n; i++)
    _at(
      '$prefix$i',
      from.add(Duration(minutes: i)),
      location: location,
      lat: lat,
      lng: lng,
    ),
];

void main() {
  test('a plan from photos: one stop per stay, a saved pin over its city, a pass-through dropped', () {
    final gion = _place(
      'gion',
      'Gion',
      PlaceKind.point,
      lat: 35.0037,
      lng: 135.7750,
    );
    final kyoto = _place('kyoto', 'Kyoto', PlaceKind.city);
    final records = [
      ..._run('t', DateTime(2017, 4, 1, 10), 4, location: 'Tokyo, Japan'),
      ..._run('n', DateTime(2017, 4, 1, 16), 2, location: 'Nagoya, Japan'),
      ..._run('k', DateTime(2017, 4, 2, 9), 3, location: 'Kyoto, Japan'),
      ..._run(
        'g',
        DateTime(2017, 4, 2, 19),
        3,
        location: 'Kyoto, Japan',
        lat: 35.0036,
        lng: 135.7751,
      ),
      ..._run('k2', DateTime(2017, 4, 3, 9), 5, location: 'Kyoto, Japan'),
      ..._run('later', DateTime(2017, 5, 1), 5, location: 'Osaka, Japan'),
    ];
    final stops = draftStops(
      records,
      DateTime(2017, 4, 1),
      DateTime(2017, 4, 3),
      [gion, kyoto],
    );
    expect(
      [for (final s in stops) (s.name, s.placeId, s.photos.length)],
      [
        ('Tokyo', null, 4),
        ('Kyoto', 'kyoto', 3),
        ('Gion', 'gion', 3),
        ('Kyoto', 'kyoto', 5),
      ],
    );
    expect(stops.first.arrived, DateTime(2017, 4, 1, 10));
  });

  test('hidden photos never make a stop', () {
    final records = [
      for (var i = 0; i < 4; i++)
        _at(
          'h$i',
          DateTime(2017, 4, 1, 10, i),
          location: 'Seoul, Korea',
          hidden: true,
        ),
    ];
    expect(
      draftStops(records, DateTime(2017, 4, 1), DateTime(2017, 4, 1), const []),
      isEmpty,
    );
  });

  test('visits split on a gap of more than two days, newest first', () {
    final photos = [
      _at('a', DateTime(2017, 4, 3, 9)),
      _at('b', DateTime(2017, 4, 5, 9)),
      _at('c', DateTime(2019, 10, 2)),
    ];
    final visits = visitsOf(photos);
    expect(
      [for (final v in visits) (v.from, v.to, v.photos.length)],
      [
        (DateTime(2019, 10, 2), DateTime(2019, 10, 2), 1),
        (DateTime(2017, 4, 3), DateTime(2017, 4, 5), 2),
      ],
    );
  });

  test('on this day: the latest earlier year with a named place', () {
    final records = [
      _at('a', DateTime(2015, 11, 2, 9), location: 'Lisbon, Portugal'),
      _at('b', DateTime(2017, 11, 2, 9), location: 'Kyoto, Japan'),
      _at('c', DateTime(2017, 11, 2, 10), location: 'Kyoto, Japan'),
      _at('d', DateTime(2019, 11, 2, 10)),
      _at('e', DateTime(2026, 11, 2, 10), location: 'Paris, France'),
    ];
    final past = onThisDay(records, DateTime(2026, 11, 2, 12))!;
    expect(
      (past.day, past.place, past.photos.length),
      (DateTime(2017, 11, 2), 'Kyoto', 2),
    );
    expect(onThisDay(records, DateTime(2026, 6, 1)), isNull);
  });

  test('suggested photos: that day, at that pin', () {
    final gion = _place(
      'gion',
      'Gion',
      PlaceKind.point,
      lat: 35.0037,
      lng: 135.7750,
    );
    final records = [
      _at('far', DateTime(2017, 4, 3, 9), lat: 35.1, lng: 135.7),
      _at('here', DateTime(2017, 4, 3, 10), lat: 35.0036, lng: 135.7751),
      _at('nextDay', DateTime(2017, 4, 4, 10), lat: 35.0036, lng: 135.7751),
    ];
    expect(
      [
        for (final r in photosAtOn(gion, records, DateTime(2017, 4, 3)))
          r.localId,
      ],
      ['here'],
    );
  });

  test('countries and cities among place names', () {
    expect(
      placeNameCounts([
        'Kyoto, Japan',
        'Osaka, Japan',
        'Japan',
        'Lisbon, Portugal',
      ]),
      (countries: 2, cities: 3),
    );
  });
}

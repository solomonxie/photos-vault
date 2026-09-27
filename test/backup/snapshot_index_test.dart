import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/backup/snapshot_index.dart';

AppSnapshot _snapshot({
  List<Map<String, Object?>> assets = const [],
  List<Map<String, Object?>> albums = const [],
  List<Map<String, Object?>> people = const [],
}) => AppSnapshot(
  version: AppSnapshot.currentVersion,
  exportedAt: DateTime(2026, 9, 26),
  assets: assets,
  albums: albums,
  people: people,
);

Map<String, Object?> _asset({
  required String localId,
  String createdAt = '2026-09-26T10:00:00.000',
  String? description,
  Object? tags,
  String? location,
  bool isVideo = false,
  bool isHidden = false,
  String? passcodeHash,
  String? deletedAt,
  String originalKey = 'photos/originals/x.heic',
  String? thumbnailKey,
}) => {
  'localId': localId,
  'createdAt': createdAt,
  'description': description,
  'tags': tags,
  'location': location,
  'isVideo': isVideo,
  'isHidden': isHidden,
  'passcodeHash': passcodeHash,
  'deletedAt': deletedAt,
  'derivatives': {
    'original': {'destinationKey': originalKey},
    'thumbnail': {'destinationKey': thumbnailKey},
  },
};

List<String> _rows(String csv) =>
    csv.split('\r\n').where((line) => line.isNotEmpty).toList();

void main() {
  test('leads with the header, and with the date', () {
    final csv = indexCsv(_snapshot(assets: [_asset(localId: 'a')]));

    expect(_rows(csv).first, startsWith('taken_at,type,file,'));
    expect(_rows(csv)[1], startsWith('2026-09-26T10:00:00.000,photo,x.heic,'));
  });

  test('sorts oldest first, so the file is the library in order', () {
    final csv = indexCsv(
      _snapshot(
        assets: [
          _asset(localId: 'new', createdAt: '2026-09-26T10:00:00.000'),
          _asset(localId: 'old', createdAt: '2011-03-12T09:14:00.000'),
        ],
      ),
    );

    expect(_rows(csv)[1], startsWith('2011-03-12'));
    expect(_rows(csv)[2], startsWith('2026-09-26'));
  });

  test('names the albums and people a photo is in', () {
    final csv = indexCsv(
      _snapshot(
        assets: [_asset(localId: 'a')],
        albums: [
          {
            'name': 'Japan',
            'localIds': ['a'],
          },
          {'name': 'Empty', 'localIds': <String>[]},
        ],
        people: [
          {
            'name': 'Mum',
            'localIds': ['a'],
          },
          {
            'name': 'Dad',
            'localIds': ['a'],
          },
        ],
      ),
    );

    expect(_rows(csv)[1], contains('Japan'));
    expect(_rows(csv)[1], contains('Mum; Dad'));
    expect(csv, isNot(contains('Empty')));
  });

  test('a hidden photo is in none of it', () {
    // A private album's objects are encrypted carriers that look like
    // ordinary pictures. An index beside them naming what they really are
    // would undo the whole feature.
    final csv = indexCsv(
      _snapshot(
        assets: [
          _asset(localId: 'flagged', isHidden: true),
          _asset(localId: 'sealed', passcodeHash: 'abc'),
          _asset(localId: 'binned', deletedAt: '2026-09-20T00:00:00.000'),
          _asset(localId: 'ordinary'),
        ],
      ),
    );

    expect(_rows(csv), hasLength(2));
    expect(csv, isNot(contains('flagged')));
    expect(csv, isNot(contains('sealed')));
    expect(csv, isNot(contains('binned')));
  });

  test('a caption with a comma or a quote in it still parses', () {
    final csv = indexCsv(
      _snapshot(
        assets: [
          _asset(
            localId: 'a',
            description: 'Kyoto, in the rain — she said "finally"',
            tags: ['temple', 'autumn'],
          ),
        ],
      ),
    );

    expect(csv, contains('"Kyoto, in the rain — she said ""finally"""'));
    expect(csv, contains('temple; autumn'));
    // One header line, one photo — the comma inside the caption did not
    // become a column break or a second row.
    expect(_rows(csv), hasLength(2));
  });

  test('says which kind of thing each row is', () {
    final csv = indexCsv(
      _snapshot(
        assets: [
          _asset(localId: 'v', isVideo: true, createdAt: '2026-01-01T00:00:00'),
        ],
      ),
    );

    expect(_rows(csv)[1], contains(',video,'));
  });
}

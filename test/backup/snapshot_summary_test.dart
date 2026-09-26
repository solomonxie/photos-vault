import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/backup/app_snapshot.dart';

Map<String, Object?> _asset(
  String id, {
  bool hidden = false,
  String? passcodeHash,
  String? deletedAt,
}) => {
  'localId': id,
  'isHidden': hidden,
  'passcodeHash': passcodeHash,
  'deletedAt': deletedAt,
};

AppSnapshot _snapshot({
  List<Map<String, Object?>> assets = const [],
  int albums = 0,
  int people = 0,
}) => AppSnapshot(
  version: AppSnapshot.currentVersion,
  exportedAt: DateTime(2026, 9, 20),
  assets: assets,
  albums: [
    for (var i = 0; i < albums; i++) {'id': 'a$i'},
  ],
  people: [
    for (var i = 0; i < people; i++) {'id': 'p$i'},
  ],
);

void main() {
  test('counts what the grid would show', () {
    final summary = _snapshot(
      assets: [_asset('a'), _asset('b')],
      albums: 3,
      people: 4,
    ).summary;

    expect(summary.photos, 2);
    expect(summary.albums, 3);
    expect(summary.people, 4);
  });

  test('the bin and the private album are not the library', () {
    final summary = _snapshot(
      assets: [
        _asset('kept'),
        _asset('binned', deletedAt: '2026-09-01T00:00:00.000Z'),
        _asset('hidden', hidden: true),
        _asset('private', passcodeHash: 'abc'),
      ],
    ).summary;

    // A count that moved when you hid something would answer the question
    // the private album exists not to answer.
    expect(summary.photos, 1);
  });

  test('an empty snapshot counts to nothing rather than throwing', () {
    final summary = _snapshot().summary;

    expect([summary.photos, summary.people, summary.albums], [0, 0, 0]);
  });

  test('a row missing the flags counts as an ordinary photo', () {
    // Written by a build before those fields existed.
    final summary = _snapshot(
      assets: [
        const {'localId': 'old'},
      ],
    ).summary;

    expect(summary.photos, 1);
  });
}

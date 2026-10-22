import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/album_suggestions.dart';
import 'package:photos_vault/storage/asset_record.dart';

List<AssetRecord> _day(DateTime day, int count, {String prefix = ''}) => [
  for (var i = 0; i < count; i++)
    AssetRecord(
      localId: '$prefix${day.month}-${day.day}-$i',
      contentHash: '$i',
      platform: 'ios',
      createdAt: day.add(Duration(minutes: i)),
      updatedAt: day,
      location: i.isEven ? 'Kyoto' : null,
    ),
];

void main() {
  test('a busy day is one suggestion, a quiet one none', () {
    final found = AlbumSuggestions.of([
      ..._day(DateTime(2026, 10, 1), 9),
      ..._day(DateTime(2026, 10, 5), 10),
    ], const {});
    expect(found, hasLength(1));
    expect(found.single.first, DateTime(2026, 10, 5));
    expect(found.single.records, hasLength(10));
    expect(found.single.place, 'Kyoto');
  });

  test('back-to-back busy days merge; a quiet day between splits', () {
    final found = AlbumSuggestions.of([
      ..._day(DateTime(2026, 10, 1), 12),
      ..._day(DateTime(2026, 10, 2), 10),
      ..._day(DateTime(2026, 10, 3), 3),
      ..._day(DateTime(2026, 10, 4), 11),
    ], const {});
    expect(
      [for (final s in found) (s.key, s.records.length)],
      [('20261004-20261004', 11), ('20261001-20261002', 22)],
    );
    expect(found.last.days, 2);
  });

  test('photos in an album do not count, and a dismissal sticks', () {
    final day = _day(DateTime(2026, 10, 1), 10);
    expect(AlbumSuggestions.of(day, {day.first.localId}), isEmpty);
    expect(
      AlbumSuggestions.of(day, const {}, dismissed: {'20261001-20261001'}),
      isEmpty,
    );
  });
}

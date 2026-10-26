import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/viewer/home_summary.dart';

void main() {
  test('round-trips; anything unreadable is null', () {
    const summary = HomeSummary(
      people: ['b', 'a'],
      personCounts: {'a': 3, 'b': 9},
      personFirsts: {'a': 'p1'},
      albumCounts: {'x': 12},
      albumCovers: {'x': 'p2'},
    );
    final back = HomeSummary.decode(summary.encode())!;
    expect(back.people, ['b', 'a']);
    expect(back.personCounts, {'a': 3, 'b': 9});
    expect(back.personFirsts, {'a': 'p1'});
    expect(back.albumCounts, {'x': 12});
    expect(back.albumCovers, {'x': 'p2'});
    expect(HomeSummary.decode(null), isNull);
    expect(HomeSummary.decode('{"people": 3}'), isNull);
    expect(HomeSummary.decode('not json'), isNull);
  });
}

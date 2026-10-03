import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/viewer/select_all.dart';

void main() {
  final ids = [for (var i = 0; i < 250; i++) i];

  test('each tap adds the next 100, newest first', () {
    final first = selectNextBatch(ids.reversed, <int>{});
    expect(first.length, 100);
    expect(first.contains(249), isTrue);
    expect(first.contains(149), isFalse);

    final second = selectNextBatch(ids.reversed, first);
    expect(second.length, 200);
    expect(second.contains(50), isTrue);

    expect(selectNextBatch(ids.reversed, second).length, 250);
  });

  test('skips what is already chosen', () {
    final picked = selectNextBatch(ids.reversed, {249, 248});
    expect(picked.length, 102);
  });
}

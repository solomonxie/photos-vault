import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/viewer/select_sweep.dart';

void main() {
  test('a sweep from a held tile selects everything it passes', () {
    final sweep = SelectSweep<int>()..begin(1);
    var selection = {1};
    for (final key in [1, 2, 3, 3, 4]) {
      selection = sweep.over(key, selection) ?? selection;
    }
    expect(selection, {1, 2, 3, 4});
  });

  test('a fresh drag starting on a selected tile deselects', () {
    final sweep = SelectSweep<int>();
    var selection = {1, 2, 3};
    for (final key in [2, 3]) {
      selection = sweep.over(key, selection) ?? selection;
    }
    expect(selection, {1});
    sweep.end();
    selection = sweep.over(2, selection) ?? selection;
    expect(selection, {1, 2});
  });
}

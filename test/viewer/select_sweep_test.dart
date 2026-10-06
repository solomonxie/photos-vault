import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/viewer/select_sweep.dart';

void main() {
  final order = [1, 2, 3, 4, 5, 6, 7, 8];
  List<int> grid() => order;

  test('a sweep selects everything between where it began and the finger', () {
    final sweep = SelectSweep<int>()..begin(2);
    var selection = {2};
    selection = sweep.over(7, selection, grid) ?? selection;
    expect(selection, {2, 3, 4, 5, 6, 7});
  });

  test('moving back shrinks the range and keeps what was there before', () {
    final sweep = SelectSweep<int>()..begin(3, base: {8});
    var selection = {3, 8};
    selection = sweep.over(6, selection, grid) ?? selection;
    expect(selection, {3, 4, 5, 6, 8});
    selection = sweep.over(4, selection, grid) ?? selection;
    expect(selection, {3, 4, 8});
  });

  test('a drag starting on a selected tile deselects the range', () {
    final sweep = SelectSweep<int>();
    var selection = {1, 2, 3, 4, 5};
    selection = sweep.over(2, selection, grid) ?? selection;
    selection = sweep.over(4, selection, grid) ?? selection;
    expect(selection, {1, 5});
    sweep.end();
    selection = sweep.over(6, selection, grid) ?? selection;
    expect(selection, {1, 5, 6});
  });
}

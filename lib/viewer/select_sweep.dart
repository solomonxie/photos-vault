import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// One hold-then-sweep (or sideways drag) across a grid, as Photos does
/// it: the tile it started on and the tile under the finger now are the two
/// ends of a range, and everything between them in grid order takes the
/// treatment the first tile decided — sweeping off a selected tile
/// deselects. Moving back shrinks the range and puts back what was there
/// before the sweep began.
class SelectSweep<K> {
  bool _active = false;
  bool _selects = true;
  K? _anchor;
  Set<K> _base = {};
  Map<K, int>? _index;
  List<K> _order = const [];
  int? _lastEnd;

  /// A hold that just selected [first]; [base] is what was selected before.
  void begin(K first, {Set<K> base = const {}}) {
    _reset();
    _active = true;
    _selects = true;
    _anchor = first;
    _base = {...base};
  }

  /// [selection] with the range from the sweep's start to [key], or null
  /// when nothing changed. [order] is the grid's order, read once a sweep.
  Set<K>? over(K key, Set<K> selection, List<K> Function() order) {
    if (!_active) {
      _reset();
      _active = true;
      _anchor = key;
      _selects = !selection.contains(key);
      _base = {...selection};
    }
    final index = _index ??= {
      for (final (i, k) in (_order = order()).indexed) k: i,
    };
    final start = index[_anchor];
    final end = index[key];
    if (start == null || end == null || end == _lastEnd) return null;
    _lastEnd = end;
    final range = _order.sublist(
      start < end ? start : end,
      (start < end ? end : start) + 1,
    );
    final next = _selects
        ? {..._base, ...range}
        : ({..._base}..removeAll(range));
    return next.length == selection.length && next.containsAll(selection)
        ? null
        : next;
  }

  void end() => _reset();

  void _reset() {
    _active = false;
    _anchor = null;
    _base = {};
    _index = null;
    _order = const [];
    _lastEnd = null;
  }
}

/// The [T] a tile under [globalPosition] carries in a `MetaData` — a hit
/// test, so nobody rebuilds grid geometry from a scroll offset.
T? metaDataUnder<T>(BuildContext context, Offset globalPosition) {
  final view = View.maybeOf(context);
  if (view == null) return null;
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, globalPosition, view.viewId);
  for (final entry in result.path) {
    final target = entry.target;
    if (target is RenderMetaData && target.metaData is T) {
      return target.metaData as T;
    }
  }
  return null;
}

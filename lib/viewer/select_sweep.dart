import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// One hold-then-sweep (or sideways drag) across a grid: every tile it
/// passes gets the same treatment, decided by the first — sweeping off a
/// selected tile deselects, so a sweep is undone by sweeping back.
class SelectSweep<K> {
  bool _active = false;
  bool _selects = true;
  Set<K> _seen = {};

  /// A hold that just selected [first].
  void begin(K first) {
    _active = true;
    _selects = true;
    _seen = {first};
  }

  /// [selection] with [key] swept over, or null when nothing changed.
  Set<K>? over(K key, Set<K> selection) {
    if (!_active) {
      _active = true;
      _selects = !selection.contains(key);
      _seen = {};
    }
    if (!_seen.add(key)) return null;
    final next = {...selection};
    _selects ? next.add(key) : next.remove(key);
    return next.length == selection.length ? null : next;
  }

  void end() {
    _active = false;
    _seen = {};
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

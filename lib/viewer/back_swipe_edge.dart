import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';

/// Keeps the left edge of a scrolling page for the back swipe.
///
/// [CupertinoPageRoute]'s edge recognizer is horizontal-only and enters the
/// arena alongside the scroll view's vertical one, so a thumb that starts
/// its swipe slightly downward hands it to the scroll and the page stays.
/// Over the same 20pt strip, this keeps pointers from reaching [child]: the
/// back swipe is left alone there and wins whatever the angle. A tap or
/// hold in the strip is handed to the [T] (a tile's `MetaData`) under it,
/// so an edge tile still opens or starts selecting.
class BackSwipeEdge<T> extends StatefulWidget {
  const BackSwipeEdge({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onLongPressMove,
    this.onLongPressEnd,
  });

  final Widget child;
  final void Function(T)? onTap;
  final void Function(T)? onLongPress;
  final void Function(Offset globalPosition)? onLongPressMove;
  final VoidCallback? onLongPressEnd;

  /// The route's own `_kBackGestureWidth`.
  static const width = 20.0;

  @override
  State<BackSwipeEdge<T>> createState() => _BackSwipeEdgeState<T>();
}

class _BackSwipeEdgeState<T> extends State<BackSwipeEdge<T>> {
  final _childKey = GlobalKey();

  T? _under(Offset globalPosition) {
    final box = _childKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return null;
    final result = BoxHitTestResult();
    box.hitTest(result, position: box.globalToLocal(globalPosition));
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is T) {
        return target.metaData as T;
      }
    }
    return null;
  }

  void _forward(void Function(T)? to, Offset globalPosition) {
    if (to == null) return;
    final hit = _under(globalPosition);
    if (hit != null) to(hit);
  }

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _childKey, child: widget.child);
    final move = widget.onLongPressMove;
    final end = widget.onLongPressEnd;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        if (ModalRoute.canPopOf(context) ?? false)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: BackSwipeEdge.width,
            child: GestureDetector(
              key: const ValueKey('backSwipeEdge'),
              behavior: HitTestBehavior.opaque,
              onTapUp: widget.onTap == null
                  ? null
                  : (d) => _forward(widget.onTap, d.globalPosition),
              onLongPressStart: widget.onLongPress == null
                  ? null
                  : (d) => _forward(widget.onLongPress, d.globalPosition),
              onLongPressMoveUpdate: move == null
                  ? null
                  : (d) => move(d.globalPosition),
              onLongPressEnd: end == null ? null : (_) => end(),
            ),
          ),
      ],
    );
  }
}

/// A tap and hold a tile carries in its `MetaData` for a [BackSwipeEdge] over
/// tiles that aren't [AssetTile]s.
class EdgeTap {
  const EdgeTap(this.onTap, [this.onLongPress]);

  final VoidCallback onTap;
  final VoidCallback? onLongPress;
}

/// [BackSwipeEdge] over [EdgeTap] tiles.
Widget backSwipeTiles({required Widget child}) => BackSwipeEdge<EdgeTap>(
  onTap: (t) => t.onTap(),
  onLongPress: (t) => t.onLongPress?.call(),
  child: child,
);

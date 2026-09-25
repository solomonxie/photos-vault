import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'photo_grid_layout.dart';

/// Renders a [PhotoGridLayout] as one lazy sliver of fixed-height rows.
///
/// Flutter's own `SliverVariedExtentList` would do this, but it walks its
/// item list from zero to work out every offset — several times per frame,
/// and once per visible child — which is fine for hundreds of rows and
/// hopeless for the tens of thousands a decade-deep library has. Every
/// offset here comes from [PhotoGridLayout]'s binary search instead, so
/// layout cost doesn't grow with library size and `jumpTo` anywhere in the
/// grid is exact rather than extrapolated.
class PhotoGridSliver extends SliverMultiBoxAdaptorWidget {
  const PhotoGridSliver({
    super.key,
    required super.delegate,
    required this.layout,
  });

  final PhotoGridLayout layout;

  @override
  RenderPhotoGridSliver createRenderObject(BuildContext context) {
    return RenderPhotoGridSliver(
      childManager: context as SliverMultiBoxAdaptorElement,
      layout: layout,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderPhotoGridSliver renderObject,
  ) {
    renderObject.gridLayout = layout;
  }
}

class RenderPhotoGridSliver extends RenderSliverFixedExtentBoxAdaptor {
  RenderPhotoGridSliver({required super.childManager, required this._layout});

  /// Not just `layout` — [RenderObject.layout] already owns that name.
  PhotoGridLayout get gridLayout => _layout;
  PhotoGridLayout _layout;
  set gridLayout(PhotoGridLayout layout) {
    if (identical(_layout, layout)) return;
    _layout = layout;
    markNeedsLayout();
  }

  @override
  double? get itemExtent => null;

  @override
  ItemExtentBuilder get itemExtentBuilder =>
      (index, dimensions) => _layout.extentOfRow(index);

  @override
  double indexToLayoutOffset(double itemExtent, int index) =>
      _layout.offsetOfRow(index);

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _layout.rowAtOffset(scrollOffset);

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset, double itemExtent) =>
      _layout.lastRowBefore(scrollOffset);

  @override
  double computeMaxScrollOffset(
    SliverConstraints constraints,
    double itemExtent,
  ) => _layout.totalExtent;

  /// The base class would extrapolate from the handful of laid-out rows;
  /// the real total is already known, and an exact one is what makes
  /// "jump to the newest photo" land on the right pixel.
  @override
  double estimateMaxScrollOffset(
    SliverConstraints constraints, {
    int? firstIndex,
    int? lastIndex,
    double? leadingScrollOffset,
    double? trailingScrollOffset,
  }) => _layout.totalExtent;
}

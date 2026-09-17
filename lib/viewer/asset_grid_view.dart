import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';

import '../storage/asset_record.dart';
import 'asset_grid.dart';
import 'date_scrubber.dart';
import 'photo_grid_layout.dart';

/// A scrolling page built around the photo grid — what every grid screen
/// (Library, Favorites, Hidden, a person's photos…) actually mounts.
///
/// Two things it does that a bare `CustomScrollView` can't:
///
///  * **Opens at the newest photo.** The grid reads oldest-at-top like
///    Photos, so a ten-year library would otherwise start a hundred
///    thousand thumbnails away from the one you just took. [jumpToNewest]
///    puts the end of the grid at the bottom of the screen, and that same
///    anchor is where a status-bar tap comes back to.
///  * **Carries the [DateScrubber]** — the right-edge handle that drags
///    years past in one gesture.
class AssetGridView extends StatefulWidget {
  const AssetGridView({
    super.key,
    required this.records,
    required this.onTap,
    required this.actionsFor,
    this.onLongPress,
    this.selectedIds,
    this.leadingSlivers = const [],
    this.trailingSlivers = const [],
    this.emptySliver,
    this.onAdd,
    this.scrubberInsets = const EdgeInsets.symmetric(vertical: 12),
  });

  /// Oldest-first — the grid draws them in the order given.
  final List<AssetRecord> records;
  final void Function(AssetRecord) onTap;
  final List<TileAction> Function(AssetRecord) actionsFor;
  final void Function(AssetRecord)? onLongPress;
  final Set<String>? selectedIds;

  /// Slivers above the grid (nav bar, search field) and below it (the
  /// Library's Collections/Utilities sections).
  final List<Widget> leadingSlivers;
  final List<Widget> trailingSlivers;

  /// Shown in the grid's place when there are no records at all.
  final Widget? emptySliver;

  /// Drawn as one more tile after the last photo, at the same size — the
  /// "add photos" square. A button in the nav bar is a place you have to
  /// know about; a tile at the end of the roll is where you already are
  /// when you notice something's missing.
  final VoidCallback? onAdd;

  /// Keeps the scrubber handle clear of whatever [leadingSlivers] pins to
  /// the top of the page.
  final EdgeInsets scrubberInsets;

  @override
  State<AssetGridView> createState() => AssetGridViewState();
}

class AssetGridViewState extends State<AssetGridView> {
  final _scrollController = ScrollController();
  final _gridKey = GlobalKey();

  PhotoGridLayout _layout = PhotoGridLayout.of(records: const [], width: 0);

  /// The first non-empty grid to be laid out anchors itself at the newest
  /// photo; after that the user's scroll position is theirs to keep.
  bool _anchored = false;

  ScrollController get scrollController => _scrollController;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Scroll offset where the grid itself begins — everything in
  /// [leadingSlivers] sits above it. Only knowable from the laid-out
  /// viewport, which is why it's read back off the render object.
  double get _gridStartOffset {
    final renderObject = _gridKey.currentContext?.findRenderObject();
    if (renderObject is! RenderSliver || renderObject.geometry == null) {
      return 0;
    }
    return renderObject.constraints.precedingScrollExtent;
  }

  /// Offset that rests the newest photo on the bottom edge of the screen —
  /// the end of the grid, with whatever follows it just below the fold.
  double? get newestOffset {
    if (!_scrollController.hasClients || _layout.isEmpty) return null;
    final position = _scrollController.position;
    if (!position.hasViewportDimension || !position.hasContentDimensions) {
      return null;
    }
    return (_gridStartOffset + _layout.totalExtent - position.viewportDimension)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  bool get isAtNewest {
    final target = newestOffset;
    return target != null && (_scrollController.offset - target).abs() < 1;
  }

  void jumpToNewest() {
    final target = newestOffset;
    if (target != null) _scrollController.jumpTo(target);
  }

  void jumpToOldest() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.minScrollExtent);
    }
  }

  /// What the status bar tap does: back to the newest photos, and from
  /// there on to the very top — so the oldest day and the search field
  /// stay one tap away rather than a hundred thousand photos away.
  void toggleAnchor() => isAtNewest ? jumpToOldest() : jumpToNewest();

  void _anchorAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _layout.isEmpty) return;
      final target = newestOffset;
      if (target == null) return;
      _anchored = true;
      _scrollController.jumpTo(target);
    });
  }

  /// What the top of the viewport is resting on, as something that
  /// survives the list changing under it: *when* that photo was taken, plus
  /// how far into its row the viewport has scrolled.
  ///
  /// The library grows from both ends — the camera-roll scan works
  /// backwards through older photos while new ones arrive at the bottom —
  /// and anything inserted above the viewport pushes what you're looking at
  /// down the page by exactly its own height. Holding a pixel offset would
  /// therefore drift the content under the reader's thumb every time a page
  /// of the scan landed. Holding a *photo* doesn't.
  ({DateTime day, double within})? _viewportPin() {
    if (!_scrollController.hasClients || _layout.isEmpty) return null;
    final position = _scrollController.position;
    if (!position.hasPixels) return null;
    final offset = position.pixels - _gridStartOffset;
    if (offset < 0 || offset >= _layout.totalExtent) return null;
    final row = _layout.rowAtOffset(offset);
    final spec = _layout.rowAt(row);
    final index = spec.isHeader
        ? _layout.sections[spec.section].firstRecord
        : spec.firstRecord;
    return (
      day: _layout.records[index].createdAt,
      within: offset - _layout.offsetOfRow(row),
    );
  }

  void _restore(({DateTime day, double within}) pin) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _layout.isEmpty || !_scrollController.hasClients) return;
      final index = _layout.indexOnOrAfter(pin.day);
      if (index >= _layout.records.length) return;
      final position = _scrollController.position;
      final target =
          (_gridStartOffset +
                  _layout.offsetOfRow(_layout.rowOfRecord(index)) +
                  pin.within)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((target - position.pixels).abs() < 0.5) return;
      _scrollController.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    // The viewport's own width, not the screen's — a grid screen can be
    // inset (a sheet, a split view) and the tile size has to match what the
    // sliver is actually handed, or every row overflows.
    return LayoutBuilder(
      builder: (context, constraints) => _build(context, constraints.maxWidth),
    );
  }

  Widget _build(BuildContext context, double width) {
    // Re-anchor when photos arrive *while the view is still resting on the
    // anchor* — the camera-roll scan lands after the first paint, and
    // nobody sitting on "the newest photo" means the one from before the
    // scan. Anywhere else on the page is the user's position to keep.
    final wasResting = !_anchored || isAtNewest;
    final grew = _layout.records.length != widget.records.length;
    final pinned = wasResting ? null : _viewportPin();
    _layout = PhotoGridLayout.of(records: widget.records, width: width);
    if (wasResting && grew) {
      _anchorAfterLayout();
    } else if (pinned != null && grew) {
      _restore(pinned);
    }

    final empty = widget.emptySliver;
    return Stack(
      children: [
        CustomScrollView(
          controller: _scrollController,
          slivers: [
            ...widget.leadingSlivers,
            if (_layout.isEmpty && empty != null)
              empty
            else
              ...assetGridSlivers(
                context: context,
                records: widget.records,
                layout: _layout,
                gridKey: _gridKey,
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                selectedIds: widget.selectedIds,
                actionsFor: widget.actionsFor,
              ),
            if (widget.onAdd != null && !_layout.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    _layout.horizontalPadding,
                    0,
                    _layout.horizontalPadding,
                    _layout.spacing,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: AddPhotosTile(
                      extent: _layout.tileExtent,
                      onTap: widget.onAdd!,
                    ),
                  ),
                ),
              ),
            ...widget.trailingSlivers,
          ],
        ),
        Positioned.fill(
          child: DateScrubber(
            insets: widget.scrubberInsets,
            controller: _scrollController,
            layout: _layout,
            gridOffset: _gridStartOffset,
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
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
///  * **Opens at its rest.** The grid reads oldest-at-top like Photos, so
///    a ten-year library would otherwise start a hundred thousand
///    thumbnails away from the one you just took. [jumpToNewest] puts the
///    end of the grid at the bottom of the screen — or, given a
///    [AssetGridView.restKey], that sliver at the top — and that same
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
    this.onMissing,
    this.onSelectDragUpdate,
    this.onSelectDragEnd,
    this.selectedIds,
    this.selection,
    this.markedId,
    this.leadingSlivers = const [],
    this.trailingSlivers = const [],
    this.restKey,
    this.restInset = 0,
    this.emptySliver,
    this.onAdd,
    this.scrubberInsets = const EdgeInsets.symmetric(vertical: 12),
    this.dateOf = PhotoGridLayout.takenAt,
  });

  /// See [PhotoGridLayout.dateOf].
  final DateTime Function(AssetRecord) dateOf;

  /// Oldest-first — the grid draws them in the order given.
  final List<AssetRecord> records;
  final void Function(AssetRecord) onTap;
  final List<TileAction> Function(AssetRecord) actionsFor;
  final void Function(AssetRecord)? onLongPress;

  /// See `PhotoManagerThumbnail.onMissing` — a tile is usually the first
  /// thing to notice a photo has left the library.
  final void Function(AssetRecord)? onMissing;

  /// See `AssetTile.onSelectDragUpdate`.
  final void Function(Offset globalPosition)? onSelectDragUpdate;
  final VoidCallback? onSelectDragEnd;
  final Set<String>? selectedIds;

  /// See `assetGridSlivers`' `selection`.
  final ValueListenable<Set<String>>? selection;

  /// The one tile this screen is about — see `AssetTile.marked`.
  final String? markedId;

  /// Slivers above the grid (nav bar, search field) and below it (the
  /// Library's Collections/Utilities sections).
  final List<Widget> leadingSlivers;
  final List<Widget> trailingSlivers;

  /// A sliver in [trailingSlivers] whose top edge, rather than the newest
  /// photo, rests at the top of the screen at the anchor — [restInset]
  /// below it, clear of a pinned bar.
  final GlobalKey? restKey;
  final double restInset;

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

  /// What [_layout] was built from — see [_build].
  List<AssetRecord>? _laidOut;
  double? _laidOutWidth;

  /// The first non-empty grid to be laid out anchors itself at the rest;
  /// after that the user's scroll position is theirs to keep.
  bool _anchored = false;

  /// The rest last jumped to: a rebuild re-anchors only when it moved.
  double? _restAt;

  /// The rest itself changed under a resting view (search opened or
  /// typed in), so the next build anchors on the new one.
  bool _restChanged = false;

  ScrollController get scrollController => _scrollController;

  @override
  void didUpdateWidget(AssetGridView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.restKey != widget.restKey ||
        oldWidget.restInset != widget.restInset) {
      final was = _restOf(oldWidget.restKey, oldWidget.restInset);
      _restChanged =
          _restChanged ||
          !_anchored ||
          (was != null && (_scrollController.offset - was).abs() < 1);
    }
  }

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
  /// the end of the grid, with whatever follows it just below the fold —
  /// or, given a [AssetGridView.restKey], that sliver's top at the top.
  double? get newestOffset => _restOf(widget.restKey, widget.restInset);

  double? _restOf(GlobalKey? restKey, double restInset) {
    final target = _unclampedRest(restKey, restInset);
    if (target == null) return null;
    final position = _scrollController.position;
    return target.clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  double? _unclampedRest(GlobalKey? restKey, double restInset) {
    if (!_scrollController.hasClients || _layout.isEmpty) return null;
    final position = _scrollController.position;
    if (!position.hasViewportDimension || !position.hasContentDimensions) {
      return null;
    }
    final rest = restKey?.currentContext?.findRenderObject();
    return rest is RenderSliver && rest.geometry != null
        ? rest.constraints.precedingScrollExtent - restInset
        : _gridStartOffset + _layout.totalExtent - position.viewportDimension;
  }

  bool get isAtNewest {
    final target = newestOffset;
    return target != null && (_scrollController.offset - target).abs() < 1;
  }

  void jumpToNewest() {
    final target = newestOffset;
    if (target == null) return;
    _restAt = target;
    _scrollController.jumpTo(target);
  }

  void jumpToOldest() {
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(_scrollController.position.minScrollExtent);
    }
  }

  /// What the status bar tap does: back to the rest, and from there on
  /// to the very top — so the oldest day and the search field
  /// stay one tap away rather than a hundred thousand photos away.
  void toggleAnchor() => isAtNewest ? jumpToOldest() : jumpToNewest();

  /// [force] when the content under the rest changed; otherwise only a
  /// rest that moved is followed — `jumpTo` ends a drag just begun.
  void _anchorAfterLayout({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _layout.isEmpty) return;
      final target = newestOffset;
      if (target == null) return;
      final last = _restAt;
      _anchored = true;
      _restAt = target;
      if (!force && last != null && (target - last).abs() < 0.5) return;
      if ((target - _scrollController.offset).abs() < 0.5) return;
      _scrollController.jumpTo(target);
    });
  }

  /// Moves the offset before the new layout is painted, so growth above
  /// the view doesn't show for a frame before the post-frame jump.
  void _correctBy(double delta) {
    if (delta.abs() < 0.5 || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.hasPixels) position.correctBy(delta);
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
      day: _layout.dateOf(_layout.records[index]),
      within: offset - _layout.offsetOfRow(row),
    );
  }

  /// Resting *below* the grid, in the sections that follow it — which on
  /// the Library is Collections and Utilities, and so is where the Hidden
  /// row lives and where tapping it leaves the page standing.
  ///
  /// Those sections keep their order and their height while the grid above
  /// them changes, so what has to stay still is the gap past the grid's
  /// end. [_viewportPin] deliberately answers `null` out here, and holding
  /// a raw pixel offset instead drops the reader as many pixels into the
  /// grid as the grid grew — several screens of older photos, on a library
  /// that just had a hidden photo put back.
  double? _pastGridPin() {
    if (!_scrollController.hasClients || _layout.isEmpty) return null;
    final position = _scrollController.position;
    if (!position.hasPixels) return null;
    final past = position.pixels - _gridStartOffset - _layout.totalExtent;
    return past < 0 ? null : past;
  }

  void _restorePastGrid(double past) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final target = (_gridStartOffset + _layout.totalExtent + past).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() < 0.5) return;
      _scrollController.jumpTo(target);
    });
  }

  /// The rest lies unclamped in the scroll range, so growth of the grid
  /// above it moves it by exactly that growth.
  bool _restInRange() {
    final target = _unclampedRest(widget.restKey, widget.restInset);
    if (target == null) return false;
    final position = _scrollController.position;
    return target >= position.minScrollExtent &&
        target <= position.maxScrollExtent;
  }

  /// [_restore]'s target, applied before the new layout is painted — only
  /// while it is inside the old range plus the growth, the new one.
  void _correctPin(({DateTime day, double within}) pin, double growth) {
    final index = _layout.indexOnOrAfter(pin.day);
    if (index >= _layout.records.length) return;
    final position = _scrollController.position;
    final target =
        _gridStartOffset +
        _layout.offsetOfRow(_layout.rowOfRecord(index)) +
        pin.within;
    if (target < position.minScrollExtent ||
        target > position.maxScrollExtent + growth) {
      return;
    }
    _correctBy(target - position.pixels);
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
    // Laying the grid out walks every record and allocates a section per
    // day, so it happens when the list or the width actually changes —
    // not on every rebuild the screen above happens to do. Identity, not
    // equality: the screens here hand down a list they computed once.
    if (!identical(_laidOut, widget.records) || _laidOutWidth != width) {
      // Re-anchor when photos arrive *while the view is still resting on
      // the anchor* — the camera-roll scan lands after the first paint,
      // and nobody resting at home means where it was before the scan.
      // Anywhere else on the page is the user's position to keep. A width
      // change (rotation) re-lays every row, so it counts as growth.
      final restChanged = _restChanged;
      _restChanged = false;
      final wasResting = !_anchored || restChanged || isAtNewest;
      final sameWidth = _laidOutWidth == width;
      final pinned = wasResting ? null : _viewportPin();
      final pastGrid = wasResting || pinned != null ? null : _pastGridPin();
      final old = _layout;
      final restInRange = wasResting && !restChanged && _restInRange();
      _layout = PhotoGridLayout.of(
        records: widget.records,
        width: width,
        dateOf: widget.dateOf,
      );
      _laidOut = widget.records;
      _laidOutWidth = width;
      // Height, not count: a date edit merging two days, or one photo in
      // and one out, moves everything below just the same.
      final grew =
          old.records.length != widget.records.length ||
          !sameWidth ||
          old.totalExtent != _layout.totalExtent;
      final growth = old.isEmpty || _layout.isEmpty || !sameWidth
          ? null
          : _layout.totalExtent - old.totalExtent;
      if (wasResting) {
        if (restInRange && growth != null) _correctBy(growth);
        if (grew || restChanged) _anchorAfterLayout(force: true);
      } else if (pinned != null && grew) {
        if (growth != null) _correctPin(pinned, growth);
        _restore(pinned);
      } else if (pastGrid != null && grew) {
        if (growth != null) _correctBy(growth);
        _restorePastGrid(pastGrid);
      }
    } else if (_restChanged) {
      _restChanged = false;
      _anchorAfterLayout(force: true);
    } else if (widget.restKey != null && _anchored && isAtNewest) {
      // What follows the rest sliver can still be filling in — People,
      // Places — which moves where a clamped rest lands, so stay on it.
      _anchorAfterLayout();
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
                onMissing: widget.onMissing,
                onSelectDragUpdate: widget.onSelectDragUpdate,
                onSelectDragEnd: widget.onSelectDragEnd,
                selectedIds: widget.selectedIds,
                selection: widget.selection,
                markedId: widget.markedId,
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

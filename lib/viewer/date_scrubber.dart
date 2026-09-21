import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import 'photo_grid_layout.dart';

/// The right-edge grab handle that drags a whole library past in one
/// gesture, labelled with the month it's about to land on — Photos' and
/// Google Photos' answer to "ten years is a lot of thumb-scrolling".
///
/// Idle it isn't there at all: it fades in the moment the list moves and
/// back out [_hideDelay] after it stops, so a still page stays clean.
///
/// It used to introduce itself once when a page opened, on the grounds
/// that a handle only appearing after you've started thumbing is a handle
/// nobody discovers. Dropped: every page in the app opens with a grid, so
/// "once" was really "every time", and a control that announces itself on
/// arrival is the thing it was drawn to avoid.
class DateScrubber extends StatefulWidget {
  const DateScrubber({
    super.key,
    required this.controller,
    required this.layout,
    required this.gridOffset,
    this.insets = const EdgeInsets.only(top: 52, bottom: 16),
  });

  final ScrollController controller;
  final PhotoGridLayout layout;

  /// Scroll offset at which the grid itself starts — everything above it
  /// (nav bar, search field) shifts the date lookup by this much.
  final double gridOffset;

  /// Keeps the handle clear of the navigation bar above and the home
  /// indicator below.
  final EdgeInsets insets;

  /// Below this much scrollable content the handle would save nobody
  /// anything, so it never shows.
  static const minScrollableExtent = 2000.0;

  /// The draggable handle itself.
  static const handleKey = Key('dateScrubberHandle');

  @override
  State<DateScrubber> createState() => _DateScrubberState();
}

class _DateScrubberState extends State<DateScrubber> {
  static const _hideDelay = Duration(seconds: 3);

  /// How much longer the handle answers a finger after it has faded.
  ///
  /// Fading and becoming untouchable used to be the same moment, so
  /// reaching for a handle you could still see half of caught nothing —
  /// and once it was gone there was no way to bring it back except
  /// scrolling, which is the thing you wanted the handle for. It stays
  /// grabbable through the fade and a moment beyond; it only ever claims
  /// vertical drags on a narrow strip, so nothing else loses a touch.
  static const _grabGrace = Duration(milliseconds: 1400);

  /// The first showing lingers — nobody has scrolled yet, so this is the
  /// one chance to be noticed at all.

  /// Quick enough to be out of the way the moment you stop, slow enough not
  /// to blink mid-flick.
  static const _fadeDuration = Duration(milliseconds: 160);
  static const _thumbHeight = 52.0;
  static const _thumbWidth = 34.0;

  /// The handle rides a short track in the upper-middle of the screen
  /// rather than the full height of it.
  ///
  /// Short, because a whole decade crossed in a third of a screen is less
  /// thumb travel, not more — the track's length is only the gearing — and
  /// because a handle parked hard against an edge reads as chrome and goes
  /// unnoticed.
  ///
  /// High, because the bottom of the page is where the rows worth tapping
  /// are, and that's exactly where you're looking when you've scrolled down
  /// to them. [_trackBottomFraction] is the floor it can't drop past,
  /// measured from the top of the screen — the rest of the page below stays
  /// the page's.
  static const _trackFraction = 0.3;
  static const _trackBottomFraction = 0.5;

  bool _visible = false;

  /// Whether a finger landing on the thumb still does something. Outlives
  /// [_visible] by [_grabGrace] — see there.
  bool _grabbable = false;
  bool _dragging = false;
  Timer? _hideTimer;
  Timer? _grabTimer;

  /// Scroll offset the current drag started from, plus the pointer's
  /// position within the track when it did — dragging is relative to the
  /// grab point so the handle doesn't jump under the finger.
  double _dragStartOffset = 0;
  double _dragStartY = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(DateScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _grabTimer?.cancel();
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  /// Where the list was the last time this fired. Null until the first
  /// callback, which is the one the framework sends while laying out —
  /// not a scroll, and treating it as one put the handle on screen the
  /// moment any page opened.
  double? _lastPixels;

  /// Whether a frame has been laid out since this was built — see [build].
  bool _measured = false;

  void _onScroll() {
    if (!mounted) return;
    final pixels = widget.controller.hasClients
        ? widget.controller.position.pixels
        : null;
    final moved = _lastPixels != null && pixels != _lastPixels;
    _lastPixels = pixels;
    if (!moved) return;
    if (!_visible || !_grabbable) {
      setState(() {
        _visible = true;
        _grabbable = true;
      });
    }
    _scheduleHide();
  }

  void _scheduleHide([Duration delay = _hideDelay]) {
    _hideTimer?.cancel();
    _grabTimer?.cancel();
    _hideTimer = Timer(delay, () {
      if (_dragging || !mounted) return;
      setState(() => _visible = false);
    });
    _grabTimer = Timer(delay + _grabGrace, () {
      if (_dragging || !mounted) return;
      setState(() => _grabbable = false);
    });
  }

  /// Null until the scroll view has been laid out — `maxScrollExtent` and
  /// friends throw before that, and this widget builds alongside the very
  /// first frame of an empty page.
  ScrollPosition? get _position {
    if (!widget.controller.hasClients) return null;
    final position = widget.controller.position;
    return position.hasContentDimensions ? position : null;
  }

  bool get _enabled {
    final position = _position;
    if (position == null || widget.layout.isEmpty) return false;
    return position.maxScrollExtent - position.minScrollExtent >=
        DateScrubber.minScrollableExtent;
  }

  double _fraction(ScrollPosition position) {
    final span = position.maxScrollExtent - position.minScrollExtent;
    if (span <= 0) return 0;
    return ((position.pixels - position.minScrollExtent) / span).clamp(
      0.0,
      1.0,
    );
  }

  void _onDragStart(DragStartDetails details) {
    final position = _position;
    if (position == null) return;
    setState(() {
      _dragging = true;
      _visible = true;
      _grabbable = true;
      _dragStartOffset = position.pixels;
      _dragStartY = details.localPosition.dy;
    });
  }

  void _onDragUpdate(DragUpdateDetails details, double trackHeight) {
    final position = _position;
    if (position == null) return;
    final travel = trackHeight - _thumbHeight;
    if (travel <= 0) return;
    final span = position.maxScrollExtent - position.minScrollExtent;
    final delta = (details.localPosition.dy - _dragStartY) / travel * span;
    position.jumpTo(
      (_dragStartOffset + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  void _onDragEnd() {
    setState(() => _dragging = false);
    _scheduleHide();
  }

  String? _label(ScrollPosition position) {
    final day = widget.layout.dayAtOffset(position.pixels - widget.gridOffset);
    if (day == null) return null;
    return DateFormat.yMMM().format(day);
  }

  @override
  Widget build(BuildContext context) {
    // `_enabled` reads the scroll position, which doesn't exist on the
    // first build — so the first answer is always "no". One rebuild after
    // layout is what lets it say yes. (The old self-introduction did this
    // as a side effect of showing itself; taking that out took this with
    // it, and the handle stopped appearing at all.)
    if (!_measured) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _measured = true);
      });
    }
    if (!_enabled) return const SizedBox.shrink();
    return Padding(
      padding: widget.insets,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final trackHeight = constraints.maxHeight * _trackFraction;
          final top = math.max(
            0.0,
            constraints.maxHeight * _trackBottomFraction - trackHeight,
          );
          return Padding(
            padding: EdgeInsets.only(top: top),
            child: SizedBox(
              width: constraints.maxWidth,
              height: trackHeight,
              child: AnimatedBuilder(
                animation: widget.controller,
                builder: (context, _) => _track(trackHeight),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _track(double trackHeight) {
    final position = _position;
    if (position == null) return const SizedBox.shrink();
    final top = _fraction(position) * (trackHeight - _thumbHeight);
    final label = _label(position);

    return AnimatedOpacity(
      opacity: _visible || _dragging ? 1 : 0,
      duration: _fadeDuration,
      child: IgnorePointer(
        ignoring: !_grabbable && !_dragging,
        child: Stack(
          children: [
            Positioned(
              right: 0,
              top: top,
              child: GestureDetector(
                key: DateScrubber.handleKey,
                // Translucent, not opaque: the handle wants vertical drags
                // and nothing else, so a *tap* that lands on it should
                // reach whatever row it's floating over rather than being
                // swallowed by a control that has no use for it.
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: _onDragStart,
                onVerticalDragUpdate: (d) => _onDragUpdate(d, trackHeight),
                onVerticalDragEnd: (_) => _onDragEnd(),
                onVerticalDragCancel: _onDragEnd,
                // The glyph itself takes no hits either: a translucent
                // detector still stops at the first child that reports one,
                // and the thumb is a painted box, so without this the tap
                // dies on the decoration rather than falling through.
                child: IgnorePointer(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (_dragging && label != null)
                        _ScrubberBubble(label: label),
                      const _ScrubberThumb(
                        width: _thumbWidth,
                        height: _thumbHeight,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScrubberThumb extends StatelessWidget {
  const _ScrubberThumb({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xE6545458),
          borderRadius: BorderRadius.circular(height / 2),
          border: Border.all(color: const Color(0x33FFFFFF)),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.chevron_up,
              size: 13,
              color: CupertinoColors.white,
            ),
            SizedBox(height: 4),
            Icon(
              CupertinoIcons.chevron_down,
              size: 13,
              color: CupertinoColors.white,
            ),
          ],
        ),
      ),
    );
  }
}

class _ScrubberBubble extends StatelessWidget {
  const _ScrubberBubble({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xF21C1C1E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: CupertinoColors.white,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

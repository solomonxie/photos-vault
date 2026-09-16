import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import 'photo_grid_layout.dart';

/// The right-edge grab handle that drags a whole library past in one
/// gesture, labelled with the month it's about to land on — Photos' and
/// Google Photos' answer to "ten years is a lot of thumb-scrolling".
///
/// Idle it isn't there at all: it fades in the moment the list moves and
/// back out [_hideDelay] after it stops, so a still page stays clean.
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
  static const _hideDelay = Duration(milliseconds: 550);

  /// The first showing lingers — nobody has scrolled yet, so this is the
  /// one chance to be noticed at all.
  static const _firstShowDelay = Duration(milliseconds: 2600);

  /// Quick enough to be out of the way the moment you stop, slow enough not
  /// to blink mid-flick.
  static const _fadeDuration = Duration(milliseconds: 160);
  static const _thumbHeight = 52.0;
  static const _thumbWidth = 34.0;

  /// The handle rides a short track in the middle of the screen rather than
  /// the full height of it. Two reasons: a handle parked against the top or
  /// bottom edge reads as part of the chrome and goes unnoticed, and a
  /// whole decade crossed in a third of a screen is less thumb travel, not
  /// more — the track's length is just the gearing.
  static const _trackFraction = 0.3;

  bool _visible = false;
  bool _dragging = false;
  bool _introduced = false;
  Timer? _hideTimer;

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
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!_visible && mounted) setState(() => _visible = true);
    _scheduleHide();
  }

  void _scheduleHide([Duration delay = _hideDelay]) {
    _hideTimer?.cancel();
    _hideTimer = Timer(delay, () {
      if (_dragging || !mounted) return;
      setState(() => _visible = false);
    });
  }

  /// Show it once, unprompted, as soon as there's enough library to scrub —
  /// a handle that only ever appears *after* you've started thumbing is a
  /// handle nobody discovers.
  void _introduce() {
    _introduced = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _visible = true);
      _scheduleHide(_firstShowDelay);
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
    if (!_enabled) return const SizedBox.shrink();
    if (!_introduced) _introduce();
    return Padding(
      padding: widget.insets,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final trackHeight = constraints.maxHeight * _trackFraction;
          return Align(
            alignment: Alignment.centerRight,
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
        ignoring: !_visible && !_dragging,
        child: Stack(
          children: [
            Positioned(
              right: 0,
              top: top,
              child: GestureDetector(
                key: DateScrubber.handleKey,
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: _onDragStart,
                onVerticalDragUpdate: (d) => _onDragUpdate(d, trackHeight),
                onVerticalDragEnd: (_) => _onDragEnd(),
                onVerticalDragCancel: _onDragEnd,
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

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';

import 'motion_playback.dart';

/// An animated GIF, under the same three-way control as a Live Photo.
///
/// Flutter's `Image` plays a GIF and offers no way to stop it, so the two
/// states are two different widgets: a decoded first frame while it's
/// still, the real `Image` while it's running. Swapping between them is
/// the pause button GIFs don't otherwise have.
class GifView extends StatefulWidget {
  const GifView({
    super.key,
    required this.file,
    required this.mode,
    required this.errorBuilder,
    this.onPlayingChanged,
  });

  final File file;
  final MotionPlayMode mode;
  final ImageErrorWidgetBuilder errorBuilder;

  /// So the badge above can light up while it moves.
  final ValueChanged<bool>? onPlayingChanged;

  @override
  State<GifView> createState() => _GifViewState();
}

class _GifViewState extends State<GifView> {
  ui.Image? _firstFrame;
  bool _held = false;

  bool get _playing =>
      widget.mode == MotionPlayMode.loop ||
      (widget.mode == MotionPlayMode.hold && _held);

  @override
  void initState() {
    super.initState();
    _decodeFirstFrame();
    // The first build is already correct; this only matters for `loop`,
    // where the badge should light up straight away.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.onPlayingChanged?.call(_playing),
    );
  }

  @override
  void didUpdateWidget(GifView old) {
    super.didUpdateWidget(old);
    if (old.file.path != widget.file.path) {
      _firstFrame?.dispose();
      _firstFrame = null;
      _decodeFirstFrame();
    }
    if (old.mode != widget.mode) {
      // Switching away from a running animation leaves it mid-loop in the
      // image cache; dropping it means the next play starts at frame one.
      if (!_playing) _rewind();
      widget.onPlayingChanged?.call(_playing);
    }
  }

  @override
  void dispose() {
    _firstFrame?.dispose();
    super.dispose();
  }

  /// One frame is all the still state needs, and decoding it here means
  /// the freeze is instant rather than a flash of nothing.
  Future<void> _decodeFirstFrame() async {
    try {
      final codec = await ui.instantiateImageCodec(
        await widget.file.readAsBytes(),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _firstFrame = frame.image);
    } catch (_) {
      // Unreadable or not an image — the running `Image` below shows the
      // error the same way any other photo would.
    }
  }

  void _rewind() => FileImage(widget.file).evict();

  void _setHeld(bool value) {
    if (_held == value) return;
    if (!value) _rewind();
    setState(() => _held = value);
    widget.onPlayingChanged?.call(_playing);
  }

  @override
  Widget build(BuildContext context) {
    final frame = _firstFrame;
    final Widget image = _playing || frame == null
        ? Image.file(
            widget.file,
            fit: BoxFit.contain,
            errorBuilder: widget.errorBuilder,
          )
        : RawImage(
            image: frame,
            fit: BoxFit.contain,
            // A GIF decoded at device pixels and drawn at logical ones is
            // half the size it should be without this.
            scale: MediaQuery.devicePixelRatioOf(context),
          );
    if (widget.mode != MotionPlayMode.hold) return image;
    return GestureDetector(
      onLongPressStart: (_) => _setHeld(true),
      onLongPressEnd: (_) => _setHeld(false),
      onLongPressCancel: () => _setHeld(false),
      child: image,
    );
  }
}

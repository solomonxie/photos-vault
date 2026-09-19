import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:video_player/video_player.dart';

import 'motion_playback.dart';

/// A still that plays its paired video, like Photos' Live Photos — on a
/// hold, on a loop, or not at all, per [mode].
///
/// The `.mov` half is resolved lazily on the first *play* — asking for it
/// up front would make every swipe through the viewer pull a video file
/// (and possibly an iCloud download) for a photo nobody watches.
class LivePhotoView extends StatefulWidget {
  const LivePhotoView({
    super.key,
    required this.still,
    required this.resolveVideo,
    required this.mode,
    this.onPlayingChanged,
  });

  final Widget still;

  /// The paired video, or `null` when there isn't one to be had (not
  /// downloaded, not a camera-roll asset, Android).
  final Future<File?> Function() resolveVideo;

  final MotionPlayMode mode;

  /// So the badge above can light up while it moves.
  final ValueChanged<bool>? onPlayingChanged;

  @override
  State<LivePhotoView> createState() => _LivePhotoViewState();
}

class _LivePhotoViewState extends State<LivePhotoView> {
  VideoPlayerController? _controller;
  bool _loading = false;
  bool _playing = false;

  /// Set when the finger lifts before the video finished loading — the
  /// clip shouldn't start playing to an audience that's already let go.
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    if (widget.mode == MotionPlayMode.loop) unawaited(_play());
  }

  @override
  void didUpdateWidget(LivePhotoView old) {
    super.didUpdateWidget(old);
    if (old.mode == widget.mode) return;
    if (widget.mode == MotionPlayMode.loop) {
      unawaited(_play());
    } else {
      unawaited(_stop());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _report(bool playing) {
    if (mounted) setState(() => _playing = playing);
    widget.onPlayingChanged?.call(playing);
  }

  Future<void> _play() async {
    _cancelled = false;
    final existing = _controller;
    if (existing != null) {
      await existing.setLooping(widget.mode == MotionPlayMode.loop);
      await existing.seekTo(Duration.zero);
      await existing.play();
      _report(true);
      return;
    }
    if (_loading) return;
    setState(() => _loading = true);
    VideoPlayerController? controller;
    try {
      final file = await widget.resolveVideo();
      if (file != null) {
        controller = VideoPlayerController.file(file);
        await controller.initialize();
      }
    } catch (_) {
      controller = null;
    }
    if (!mounted) {
      await controller?.dispose();
      return;
    }
    setState(() {
      _loading = false;
      _controller = controller;
    });
    if (controller == null || _cancelled) return;
    await controller.setLooping(widget.mode == MotionPlayMode.loop);
    await controller.play();
    _report(true);
  }

  Future<void> _stop() async {
    _cancelled = true;
    final controller = _controller;
    if (controller == null) return;
    await controller.pause();
    await controller.seekTo(Duration.zero);
    _report(false);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final frames = Stack(
      fit: StackFit.expand,
      children: [
        widget.still,
        if (_playing && controller != null)
          Center(
            child: AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
          ),
      ],
    );
    if (widget.mode != MotionPlayMode.hold) return frames;
    return GestureDetector(
      onLongPressStart: (_) => _play(),
      onLongPressEnd: (_) => _stop(),
      onLongPressCancel: _stop,
      child: frames,
    );
  }
}

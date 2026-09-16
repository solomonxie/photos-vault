import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:video_player/video_player.dart';

import '../l10n/app_localizations.dart';

/// A still that plays its paired video while held, like Photos' Live
/// Photos. The `.mov` half is resolved lazily on the first press — asking
/// for it up front would make every swipe through the viewer pull a video
/// file (and possibly an iCloud download) for a photo nobody holds.
class LivePhotoView extends StatefulWidget {
  const LivePhotoView({
    super.key,
    required this.still,
    required this.resolveVideo,
  });

  final Widget still;

  /// The paired video, or `null` when there isn't one to be had (not
  /// downloaded, not a camera-roll asset, Android).
  final Future<File?> Function() resolveVideo;

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
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _onHoldStart() async {
    _cancelled = false;
    final existing = _controller;
    if (existing != null) {
      await existing.seekTo(Duration.zero);
      await existing.play();
      if (mounted) setState(() => _playing = true);
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
    await controller.play();
    if (mounted) setState(() => _playing = true);
  }

  Future<void> _onHoldEnd() async {
    _cancelled = true;
    final controller = _controller;
    if (controller == null) return;
    await controller.pause();
    await controller.seekTo(Duration.zero);
    if (mounted) setState(() => _playing = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = _controller;
    return GestureDetector(
      onLongPressStart: (_) => _onHoldStart(),
      onLongPressEnd: (_) => _onHoldEnd(),
      onLongPressCancel: _onHoldEnd,
      child: Stack(
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
          Positioned(
            top: 12,
            left: 12,
            child: _LiveBadge(
              label: l10n.detailLivePhotoBadge,
              active: _playing || _loading,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: active ? const Color(0xE6FFFFFF) : const Color(0x8C000000),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          CupertinoIcons.smallcircle_circle,
          size: 14,
          color: active ? CupertinoColors.black : CupertinoColors.white,
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: active ? CupertinoColors.black : CupertinoColors.white,
          ),
        ),
      ],
    ),
  );
}

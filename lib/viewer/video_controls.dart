import 'package:flutter/cupertino.dart';
import 'package:video_player/video_player.dart';

/// The playback bar under a video in the viewer: play/pause, elapsed and
/// remaining time, a draggable timeline, and mute — Photos' set, minus the
/// filmstrip (which would need frame extraction this app doesn't do).
///
/// Scrubbing seeks live rather than only on release, so the frame under the
/// thumb is the frame you see, and playback is paused for the duration of
/// the drag and resumed after if it was running.
class VideoControls extends StatefulWidget {
  const VideoControls({super.key, required this.controller});

  final VideoPlayerController controller;

  @override
  State<VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<VideoControls> {
  Duration? _dragPosition;
  bool _resumeAfterDrag = false;

  static String _formatTime(Duration d) {
    final seconds = d.inSeconds.clamp(0, 359999);
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : m.toString();
    return '${h > 0 ? '$h:' : ''}$mm:${s.toString().padLeft(2, '0')}';
  }

  Duration _positionAt(double dx, double width, Duration duration) {
    if (width <= 0) return Duration.zero;
    final fraction = (dx / width).clamp(0.0, 1.0);
    return duration * fraction;
  }

  void _onDragStart(double dx, double width, Duration duration) {
    _resumeAfterDrag = widget.controller.value.isPlaying;
    if (_resumeAfterDrag) widget.controller.pause();
    _seekTo(_positionAt(dx, width, duration));
  }

  void _seekTo(Duration position) {
    setState(() => _dragPosition = position);
    widget.controller.seekTo(position);
  }

  Future<void> _onDragEnd() async {
    setState(() => _dragPosition = null);
    if (_resumeAfterDrag) await widget.controller.play();
    _resumeAfterDrag = false;
  }

  void _togglePlay() {
    final controller = widget.controller;
    if (controller.value.isPlaying) {
      controller.pause();
      return;
    }
    // Replay from the start rather than sitting on the last frame, which
    // is what a tap on a finished video means.
    if (controller.value.position >= controller.value.duration) {
      controller.seekTo(Duration.zero);
    }
    controller.play();
  }

  void _toggleMute() {
    final muted = widget.controller.value.volume == 0;
    widget.controller.setVolume(muted ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        if (!value.isInitialized) return const SizedBox.shrink();
        final duration = value.duration;
        final position = _dragPosition ?? value.position;
        final remaining = duration - position;

        return Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          color: const Color(0x99000000),
          child: Row(
            children: [
              _IconButton(
                icon: value.isPlaying
                    ? CupertinoIcons.pause_fill
                    : CupertinoIcons.play_fill,
                onPressed: _togglePlay,
              ),
              _TimeLabel(text: _formatTime(position)),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) {
                      widget.controller.seekTo(
                        _positionAt(
                          d.localPosition.dx,
                          constraints.maxWidth,
                          duration,
                        ),
                      );
                    },
                    onHorizontalDragStart: (d) => _onDragStart(
                      d.localPosition.dx,
                      constraints.maxWidth,
                      duration,
                    ),
                    onHorizontalDragUpdate: (d) => _seekTo(
                      _positionAt(
                        d.localPosition.dx,
                        constraints.maxWidth,
                        duration,
                      ),
                    ),
                    onHorizontalDragEnd: (_) => _onDragEnd(),
                    onHorizontalDragCancel: _onDragEnd,
                    child: SizedBox(
                      height: 28,
                      child: Center(
                        child: _Timeline(
                          progress: duration.inMilliseconds == 0
                              ? 0
                              : position.inMilliseconds /
                                    duration.inMilliseconds,
                          active: _dragPosition != null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              _TimeLabel(text: '-${_formatTime(remaining)}'),
              _IconButton(
                icon: value.volume == 0
                    ? CupertinoIcons.speaker_slash_fill
                    : CupertinoIcons.speaker_2_fill,
                onPressed: _toggleMute,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.progress, required this.active});

  final double progress;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final height = active ? 8.0 : 4.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final filled = (width * progress.clamp(0.0, 1.0)).clamp(0.0, width);
        return Stack(
          alignment: Alignment.centerLeft,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: height,
              decoration: BoxDecoration(
                color: const Color(0x4DFFFFFF),
                borderRadius: BorderRadius.circular(height / 2),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: height,
              width: filled,
              decoration: BoxDecoration(
                color: CupertinoColors.white,
                borderRadius: BorderRadius.circular(height / 2),
              ),
            ),
            Positioned(
              left: (filled - 6).clamp(0.0, width > 12 ? width - 12 : 0.0),
              child: Container(
                width: 12,
                height: 12,
                decoration: const BoxDecoration(
                  color: CupertinoColors.white,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Text(
      text,
      style: const TextStyle(
        color: CupertinoColors.white,
        fontSize: 12,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    ),
  );
}

class _IconButton extends StatelessWidget {
  const _IconButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onPressed,
    child: SizedBox(
      width: 36,
      height: 36,
      child: Icon(icon, color: CupertinoColors.white, size: 20),
    ),
  );
}

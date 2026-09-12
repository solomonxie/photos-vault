import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../l10n/app_localizations.dart';

const _videoExtensions = {'.mp4', '.mov', '.m4v'};

/// Minimal preview for a manually-added file — full detail viewer with
/// thumbnail->medium->original progressive load (T4.2) lands once the
/// derivative pipeline (Phase 2) exists; this just opens the original file
/// directly so there's something to see today.
class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.filePath, required this.title});

  final String filePath;
  final String title;

  static bool isVideoPath(String path) {
    final lower = path.toLowerCase();
    return _videoExtensions.any(lower.endsWith);
  }

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  VideoPlayerController? _videoController;
  Object? _videoError;

  @override
  void initState() {
    super.initState();
    if (DetailScreen.isVideoPath(widget.filePath)) {
      final controller = VideoPlayerController.file(File(widget.filePath));
      _videoController = controller;
      controller
          .initialize()
          .then((_) {
            if (mounted) setState(() {});
          })
          .catchError((Object e) {
            if (mounted) setState(() => _videoError = e);
          });
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      backgroundColor: Colors.black,
      body: Center(child: _videoController != null ? _buildVideo() : _buildImage()),
    );
  }

  Widget _buildImage() {
    final l10n = AppLocalizations.of(context)!;
    return Image.file(
      File(widget.filePath),
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => _MissingFileNote(message: l10n.detailFileUnavailable),
    );
  }

  Widget _buildVideo() {
    final l10n = AppLocalizations.of(context)!;
    if (_videoError != null) {
      return _MissingFileNote(message: l10n.detailFileUnavailable);
    }
    final controller = _videoController!;
    if (!controller.value.isInitialized) {
      return const CircularProgressIndicator();
    }
    return AspectRatio(
      aspectRatio: controller.value.aspectRatio,
      child: GestureDetector(
        onTap: () => setState(() {
          controller.value.isPlaying ? controller.pause() : controller.play();
        }),
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(controller),
            if (!controller.value.isPlaying)
              const Icon(Icons.play_circle_outline, size: 64, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}

class _MissingFileNote extends StatelessWidget {
  const _MissingFileNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.broken_image_outlined, size: 48, color: Colors.white54),
        const SizedBox(height: 12),
        Text(message, style: const TextStyle(color: Colors.white54)),
      ],
    );
  }
}

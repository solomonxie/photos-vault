import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:video_player/video_player.dart';

import '../l10n/app_localizations.dart';
import '../storage/asset_record.dart';

const _videoExtensions = {'.mp4', '.mov', '.m4v'};

bool isVideoPath(String path) {
  final lower = path.toLowerCase();
  return _videoExtensions.any(lower.endsWith);
}

/// Full-screen, swipe-between-items viewer — the Photos-app pattern: black
/// background, "Done" to dismiss, a bottom action bar. Not the full
/// thumbnail->medium->original progressive load (T4.2, needs the derivative
/// pipeline from Phase 2); it opens the original file directly.
class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.records, required this.initialIndex, required this.onDelete});

  final List<AssetRecord> records;
  final int initialIndex;
  final Future<void> Function(AssetRecord record) onDelete;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late final PageController _pageController = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  late List<AssetRecord> _records = widget.records;

  Future<void> _delete() async {
    final record = _records[_index];
    await widget.onDelete(record);
    if (!mounted) return;
    if (_records.length <= 1) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _records = [..._records]..removeAt(_index);
      if (_index >= _records.length) _index = _records.length - 1;
    });
  }

  void _showComingSoon(String message) {
    showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        message: Text(message),
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppLocalizations.of(context)!.actionCancel),
        ),
      ),
    );
  }

  void _showInfo() {
    final l10n = AppLocalizations.of(context)!;
    final record = _records[_index];
    final path = record.sourcePath ?? record.localId;
    showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(path.split('/').last),
        message: Text(
          '${l10n.detailInfoAdded}: ${record.createdAt.toLocal()}\n'
          '${l10n.detailInfoStatus}: ${record.stateOf(DerivativeKind.original).status.name}',
        ),
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.black,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(l10n.detailDoneButton, style: const TextStyle(color: CupertinoColors.systemYellow)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _records.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => _MediaPage(record: _records[i]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => _showComingSoon(l10n.detailShareComingSoon),
                    child: const Icon(CupertinoIcons.share, color: CupertinoColors.systemYellow),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => _showComingSoon(l10n.detailFavoriteComingSoon),
                    child: const Icon(CupertinoIcons.heart, color: CupertinoColors.systemYellow),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _showInfo,
                    child: const Icon(CupertinoIcons.info_circle, color: CupertinoColors.systemYellow),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _delete,
                    child: const Icon(CupertinoIcons.trash, color: CupertinoColors.systemYellow),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaPage extends StatefulWidget {
  const _MediaPage({required this.record});

  final AssetRecord record;

  @override
  State<_MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<_MediaPage> {
  VideoPlayerController? _videoController;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final path = widget.record.sourcePath;
    if (path != null && isVideoPath(path)) {
      final controller = VideoPlayerController.file(File(path));
      _videoController = controller;
      controller
          .initialize()
          .then((_) {
            if (mounted) setState(() {});
          })
          .catchError((Object e) {
            if (mounted) setState(() => _error = e);
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
    final l10n = AppLocalizations.of(context)!;
    final path = widget.record.sourcePath;
    if (path == null) {
      return _MissingFileNote(message: l10n.detailFileUnavailable);
    }
    if (_error != null) {
      return _MissingFileNote(message: l10n.detailFileUnavailable);
    }
    final controller = _videoController;
    if (controller != null) {
      if (!controller.value.isInitialized) {
        return const Center(child: CupertinoActivityIndicator(color: CupertinoColors.white));
      }
      return Center(
        child: AspectRatio(
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
                  const Icon(CupertinoIcons.play_circle, size: 64, color: CupertinoColors.white),
              ],
            ),
          ),
        ),
      );
    }
    return Center(
      child: Image.file(
        File(path),
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => _MissingFileNote(message: l10n.detailFileUnavailable),
      ),
    );
  }
}

class _MissingFileNote extends StatelessWidget {
  const _MissingFileNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(CupertinoIcons.exclamationmark_triangle, size: 48, color: CupertinoColors.systemGrey),
          const SizedBox(height: 12),
          Text(message, style: const TextStyle(color: CupertinoColors.systemGrey)),
        ],
      ),
    );
  }
}

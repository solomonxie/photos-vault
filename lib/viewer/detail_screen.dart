import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import '../l10n/app_localizations.dart';
import '../storage/asset_record.dart';

const _videoExtensions = {'.mp4', '.mov', '.m4v'};

bool isVideoPath(String path) {
  final lower = path.toLowerCase();
  return _videoExtensions.any(lower.endsWith);
}

/// Full-screen, swipe-between-items viewer — the Photos-app pattern: black
/// background, "Done" to dismiss, a bottom action bar, and — scroll down
/// past the photo — an info panel (date, size, dimensions, format,
/// location, backup status). Not the full thumbnail->medium->original
/// progressive load (T4.2, needs the derivative pipeline from Phase 2); it
/// opens the original file directly.
class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.records,
    required this.initialIndex,
    required this.onDelete,
    required this.onToggleFavorite,
  });

  final List<AssetRecord> records;
  final int initialIndex;

  /// Returns whether the delete actually happened — `false` if the user
  /// cancelled the confirmation, in which case nothing here should change.
  final Future<bool> Function(AssetRecord record) onDelete;
  final Future<void> Function(AssetRecord record) onToggleFavorite;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late final PageController _pageController = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  late List<AssetRecord> _records = widget.records;

  Future<void> _delete() async {
    final record = _records[_index];
    final deleted = await widget.onDelete(record);
    if (!deleted || !mounted) return;
    if (_records.length <= 1) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _records = [..._records]..removeAt(_index);
      if (_index >= _records.length) _index = _records.length - 1;
    });
  }

  Future<void> _toggleFavorite() async {
    final record = _records[_index];
    await widget.onToggleFavorite(record);
    if (!mounted) return;
    setState(() => _records = [..._records]..[_index] = record.withFavorite(!record.isFavorite));
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
                    child: Text(l10n.detailDoneButton, style: const TextStyle(color: CupertinoColors.white)),
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
                    child: const Icon(CupertinoIcons.share, color: CupertinoColors.white),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _toggleFavorite,
                    child: Icon(
                      _records[_index].isFavorite ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
                      color: CupertinoColors.white,
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: _delete,
                    child: const Icon(CupertinoIcons.trash, color: CupertinoColors.white),
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

  /// Pulling down while already at the top rubber-bands the scroll position
  /// negative (`BouncingScrollPhysics`) instead of doing nothing — past
  /// [_dismissPullThreshold] of that, dismiss back to the grid, same as
  /// real Photos. Checked against live drag updates only (`dragDetails !=
  /// null`) — once the finger lifts, the same negative position keeps
  /// generating updates as it springs back to 0, which would otherwise
  /// trigger this on every release, however small the actual pull was.
  bool _dismissed = false;
  static const _dismissPullThreshold = 80.0;

  bool _onScrollNotification(ScrollNotification notification) {
    if (!_dismissed &&
        notification is ScrollUpdateNotification &&
        notification.dragDetails != null &&
        notification.metrics.pixels < -_dismissPullThreshold) {
      _dismissed = true;
      Navigator.of(context).pop();
    }
    return false;
  }

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

  Widget _media(AppLocalizations l10n) {
    final path = widget.record.sourcePath;
    if (path == null || _error != null) {
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: LayoutBuilder(
        builder: (context, constraints) => CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: SizedBox(height: constraints.maxHeight, child: _media(l10n))),
            SliverToBoxAdapter(child: _InfoPanel(record: widget.record, videoController: _videoController)),
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

/// The "swipe/scroll up for details" panel real Photos shows below the
/// image — date/time header, then a plain list of file facts. Location is
/// always "No Location": this app doesn't read EXIF GPS tags (T4.x).
class _InfoPanel extends StatefulWidget {
  const _InfoPanel({required this.record, required this.videoController});

  final AssetRecord record;
  final VideoPlayerController? videoController;

  @override
  State<_InfoPanel> createState() => _InfoPanelState();
}

class _InfoPanelState extends State<_InfoPanel> {
  int? _bytes;
  int? _width;
  int? _height;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final path = widget.record.sourcePath;
    if (path == null) return;
    final file = File(path);
    int? bytes, width, height;
    try {
      bytes = (await file.stat()).size;
    } catch (_) {}
    if (!isVideoPath(path)) {
      try {
        final codec = await ui.instantiateImageCodec(await file.readAsBytes());
        final frame = await codec.getNextFrame();
        width = frame.image.width;
        height = frame.image.height;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _width = width;
      _height = height;
    });
  }

  String _statusLabel(AppLocalizations l10n, UploadStatus status) => switch (status) {
    UploadStatus.pending => l10n.libraryStatusPending,
    UploadStatus.uploading => l10n.libraryStatusUploading,
    UploadStatus.uploaded => l10n.libraryStatusUploaded,
    UploadStatus.failed => l10n.libraryStatusFailed,
  };

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var value = bytes / 1024;
    var i = 0;
    while (value >= 1024 && i < units.length - 1) {
      value /= 1024;
      i++;
    }
    return '${value.toStringAsFixed(1)} ${units[i]}';
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final record = widget.record;
    final path = record.sourcePath;
    final format = path != null && p.extension(path).isNotEmpty ? p.extension(path).substring(1).toUpperCase() : null;
    final duration = widget.videoController?.value.duration;

    return Container(
      color: CupertinoColors.black,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 5,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(color: CupertinoColors.systemGrey, borderRadius: BorderRadius.circular(3)),
            ),
          ),
          Text(
            DateFormat.yMMMMEEEEd().add_jm().format(record.createdAt.toLocal()),
            style: const TextStyle(color: CupertinoColors.white, fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          _InfoRow(label: l10n.detailInfoLocation, value: l10n.detailInfoNoLocation),
          if (_width != null && _height != null) _InfoRow(label: l10n.detailInfoDimensions, value: '$_width × $_height'),
          if (duration != null) _InfoRow(label: l10n.detailInfoDuration, value: _formatDuration(duration)),
          if (_bytes != null) _InfoRow(label: l10n.detailInfoFileSize, value: _formatBytes(_bytes!)),
          if (format != null) _InfoRow(label: l10n.detailInfoFormat, value: format),
          _InfoRow(
            label: l10n.detailInfoStatus,
            value: _statusLabel(l10n, record.stateOf(DerivativeKind.original).status),
            showDivider: false,
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.showDivider = true});

  final String label;
  final String value;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(color: CupertinoColors.systemGrey)),
              Text(value, style: const TextStyle(color: CupertinoColors.white)),
            ],
          ),
        ),
        if (showDivider) Container(height: 1, color: CupertinoColors.systemGrey5),
      ],
    );
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/gestures.dart' show VelocityTracker;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../photos/image_pipeline.dart';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../l10n/app_localizations.dart';
import '../photos/library_metadata.dart';
import '../photos/ai_touch_up_queue.dart';
import '../photos/derived_asset.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../photos/ai_analysis.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/ai_vision_service.dart';
import '../photos/face_crops.dart';
import '../photos/face_identity.dart';
import '../photos/on_device_analysis.dart';
import '../photos/photo_library_service.dart';
import '../photos/photo_location.dart';
import '../photos/suggestion_review.dart';
import '../settings/backup_targets_store.dart';
import '../settings/bucket_location.dart';
import 'asset_grid.dart';
import '../storage/album.dart';
import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/original_restore.dart';
import 'person_avatar.dart';
import 'person_page_screen.dart';
import 'gif_view.dart';
import 'live_photo_view.dart';
import 'motion_playback.dart';
import 'photo_edit_screen.dart';
import 'person_picker_sheet.dart';
import 'search_picker_sheet.dart';
import 'video_controls.dart';

/// Matches `CupertinoThemeData.scaffoldBackgroundColor` in app.dart — pure
/// black looked out of place next to every other screen's dark grey.
const _screenBackground = Color(0xFF1C1C1E);

/// Still-image re-encode formats offered by "Export As…" — decoding and
/// re-encoding is pure Dart (the `image` package), so this only ever
/// touches still images; videos share their original file as-is (no
/// bundled transcoder).
enum _ExportFormat { jpg, png, webp }

/// What the share sheet offers. The last two only once the photo has an
/// object in a bucket — sharing is "where else can this go", and by then
/// it is already somewhere else.
enum _ShareChoice { original, exportAs, showInBucket, openInBrowser }

enum _EditChoice { crop, rotate, aiTouchUp }

/// Runs off the UI isolate via [compute] — decode+encode of a full-size
/// photo is heavy enough to jank a frame otherwise.
Uint8List? _reencode((Uint8List bytes, _ExportFormat format) args) {
  final decoded = decodePhoto(args.$1);
  if (decoded == null) return null;
  return switch (args.$2) {
    _ExportFormat.jpg => Uint8List.fromList(img.encodeJpg(decoded)),
    _ExportFormat.png => Uint8List.fromList(img.encodePng(decoded)),
    _ExportFormat.webp => Uint8List.fromList(img.encodeWebP(decoded)),
  };
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
    required this.assetRecordStore,
    this.personStore,
    this.albumStore,
    this.resolvePhotoManagerFile,
    this.resolveLivePhotoVideo,
    this.resolvePlaceName,
    this.restoreOriginal,
    this.restoreThumbnail,
    this.onDeviceAnalysis,
    this.aiVisionService,
  });

  final List<AssetRecord> records;
  final int initialIndex;

  /// Returns whether the delete actually happened — `false` if the user
  /// cancelled the confirmation, in which case nothing here should change.
  final Future<bool> Function(AssetRecord record) onDelete;
  final Future<void> Function(AssetRecord record) onToggleFavorite;

  /// Backs the info panel's editable fields (date/time, location,
  /// description, tags). Required since every caller already holds one.
  final AssetRecordStore assetRecordStore;

  /// Backs the info panel's People section. Self-constructed (same `?? `
  /// pattern as `LibraryScreen`'s own) when a caller doesn't already have
  /// one to pass.
  final PersonStore? personStore;

  /// Lets the info panel show and edit which albums the photo is in. The
  /// viewer works without one — that section just isn't offered.
  final AlbumStore? albumStore;

  /// Resolves a `photoManager` record's on-disk file. Defaults to
  /// [PhotoLibraryService.resolveFile]; overridable so widget tests never
  /// touch the real `photo_manager` platform channel.
  final Future<File?> Function(AssetRecord record)? resolvePhotoManagerFile;

  /// Resolves the `.mov` half of a Live Photo for hold-to-play. Defaults to
  /// [PhotoLibraryService.resolveLivePhotoVideo]; overridable so widget
  /// tests never touch the real `photo_manager` platform channel.
  final Future<File?> Function(AssetRecord record)? resolveLivePhotoVideo;

  /// Reverse-geocodes a photo's GPS tag into a place name, to fill an empty
  /// Location. Defaults to a real [PhotoLocationService]; overridable so
  /// widget tests never touch the geocoder plugin.
  final Future<String?> Function(AssetRecord record)? resolvePlaceName;

  /// Re-downloads a cloud-only asset's original ([AssetRecord.localDeleted]).
  /// Defaults to a real [OriginalRestore]; overridable so widget tests never
  /// make a network call.
  final Future<String?> Function(AssetRecord record)? restoreOriginal;

  /// Re-downloads just the cached thumbnail — see
  /// [OriginalRestore.restoreThumbnail]. Same defaulting, same reason.
  final Future<String?> Function(AssetRecord record)? restoreThumbnail;

  /// Backs "Auto Suggest" / "AI Suggest" in the info panel. Both build
  /// themselves on first use, so a test that doesn't tap them never
  /// constructs a database or a platform channel.
  final OnDeviceAnalysisService? onDeviceAnalysis;
  final AiVisionService? aiVisionService;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late final PageController _pageController = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  late List<AssetRecord> _records = widget.records;
  late final PersonStore _personStore = widget.personStore ?? PersonStore();

  /// One setting shared by every page in the pager: swiping from one Live
  /// Photo to the next must not change how they play.
  late final MotionPlaybackSetting _motionPlayback = MotionPlaybackSetting(
    settings: widget.assetRecordStore,
  )..load();

  /// One per visited page (keyed by `localId`), so the info-circle button
  /// can reveal the *current* page's info panel without needing a fresh
  /// controller lookup through the `PageView`.
  final _scrollControllers = <String, ScrollController>{};

  ScrollController _scrollControllerFor(AssetRecord record) =>
      _scrollControllers.putIfAbsent(record.localId, () => ScrollController());

  /// Whether the photo on screen is zoomed in — see the pager's `physics`.
  bool _zoomed = false;

  /// Whether a pull-to-dismiss is under way on the current page. The pager
  /// stands down while it is: one drag, one meaning.
  bool _pulling = false;

  /// How far that pull has got, 0 to 1 — `null` when there isn't one.
  ///
  /// A notifier rather than state because it changes every frame of the
  /// drag, and rebuilding the pager (and with it both pages and their info
  /// panels) sixty times a second to fade a toolbar is how a gesture that
  /// should feel attached to the finger starts to stutter. Only the chrome
  /// and the backdrop listen.
  final ValueNotifier<double?> _pull = ValueNotifier(null);

  /// The backdrop, warmed on touch rather than on drag — see
  /// `_MediaPageState._onPointerDown`. A pull in progress owns it: letting
  /// a finger lift put it back mid-drag would cover the grid again halfway
  /// through dragging the photo off it.
  void _onPullMayStart(bool possible) {
    if (_pulling && !possible) return;
    _setBackdropVisible(possible);
  }

  void _onPull(double? progress) {
    _pull.value = progress;
    final pulling = progress != null;
    if (pulling == _pulling) return;
    setState(() => _pulling = pulling);
    // What's underneath has to be *there* to be dragged away from. The
    // route is opaque the rest of the time so the grid below isn't being
    // painted under a photo that covers it.
    _setBackdropVisible(pulling);
    // The pager had already taken a few pixels of this drag before it
    // turned out to be a pull, and cancelling its drag leaves it parked
    // off-centre. Put it back on the page it was on.
    if (!pulling) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageController.hasClients) return;
        _pageController.animateToPage(
          _index,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      });
    }
  }

  void _setBackdropVisible(bool visible) {
    final route = ModalRoute.of(context);
    if (route == null || route.overlayEntries.isEmpty) return;
    // Mid-transition the route is already see-through and owns the flag —
    // taking it back here would cut the opening animation short.
    if (!(route.animation?.isCompleted ?? true)) return;
    route.overlayEntries.first.opaque = visible ? false : route.opaque;
  }

  @override
  void dispose() {
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    _pull.dispose();
    _motionPlayback.dispose();
    super.dispose();
  }

  /// Same effect as dragging the photo up: scrolls exactly one viewport's
  /// worth, landing on the info panel's top instead of anywhere within it.
  void _revealInfoPanel() {
    final controller = _scrollControllers[_records[_index].localId];
    if (controller == null || !controller.hasClients) return;
    controller.animateTo(
      controller.position.viewportDimension,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _updateRecord(AssetRecord updated) {
    setState(() {
      _records = [..._records];
      final i = _records.indexWhere((r) => r.localId == updated.localId);
      if (i != -1) _records[i] = updated;
    });
  }

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
    setState(
      () =>
          _records = [..._records]
            ..[_index] = record.withFavorite(!record.isFavorite),
    );
  }

  void _showMessage(String message) {
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

  /// `manualFile` records already have a `sourcePath`; `photoManager` ones
  /// are resolved on demand (same as `_MediaPageState` does for display) —
  /// this doesn't share that widget's cached path since Share/Edit live in
  /// this state, not that one's.
  Future<String?> _resolvePath(AssetRecord record) async {
    final direct = record.sourcePath;
    if (direct != null) return direct;
    if (record.sourceType != AssetSourceType.photoManager) return null;
    final resolver =
        widget.resolvePhotoManagerFile ?? PhotoLibraryService.resolveFile;
    try {
      return (await resolver(record))?.path;
    } catch (_) {
      return null;
    }
  }

  /// "Share Original" (as-is, any media type), "Export As…" (stills only,
  /// re-encoded into another format), and — once the photo has landed in a
  /// bucket — the two ways to the object it landed as.
  ///
  /// The bucket options don't need the local file, which is the point: a
  /// photo whose bytes are gone from this phone is exactly when somebody
  /// wants to know where the copy is.
  Future<void> _showShareSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final record = _records[_index];
    final original = record.stateOf(DerivativeKind.original);
    final objectKey = original.status == UploadStatus.uploaded
        ? original.destinationKey
        : null;
    final path = await _resolvePath(record);
    if (!mounted) return;
    if (path == null && objectKey == null) {
      _showMessage(l10n.detailFileUnavailable);
      return;
    }
    final choice = await showCupertinoModalPopup<_ShareChoice>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        actions: [
          if (path != null) ...[
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(context).pop(_ShareChoice.original),
              child: Text(l10n.detailShareOriginalOption),
            ),
            if (!record.countsAsVideo)
              CupertinoActionSheetAction(
                onPressed: () =>
                    Navigator.of(context).pop(_ShareChoice.exportAs),
                child: Text(l10n.detailExportAsOption),
              ),
          ],
          if (objectKey != null) ...[
            CupertinoActionSheetAction(
              onPressed: () =>
                  Navigator.of(context).pop(_ShareChoice.showInBucket),
              child: Text(l10n.bucketShowInBucket),
            ),
            CupertinoActionSheetAction(
              onPressed: () =>
                  Navigator.of(context).pop(_ShareChoice.openInBrowser),
              child: Text(l10n.bucketOpenInBrowser),
            ),
          ],
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case _ShareChoice.original:
        await SharePlus.instance.share(ShareParams(files: [XFile(path!)]));
      case _ShareChoice.exportAs:
        await _exportAndShare(path!);
      case _ShareChoice.showInBucket:
        await showObjectInBucketBrowser(context, objectKey: objectKey!);
      case _ShareChoice.openInBrowser:
        await openObjectInSystemBrowser(context, objectKey: objectKey!);
    }
  }

  Future<void> _exportAndShare(String path) async {
    final l10n = AppLocalizations.of(context)!;
    final format = await showCupertinoModalPopup<_ExportFormat>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(l10n.detailExportAsOption),
        actions: [
          for (final format in _ExportFormat.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(context).pop(format),
              child: Text(format.name.toUpperCase()),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (format == null || !mounted) return;
    try {
      final bytes = await File(path).readAsBytes();
      final encoded = await compute(_reencode, (bytes, format));
      if (encoded == null) throw const FormatException('decode failed');
      final dir = await getTemporaryDirectory();
      final outPath = p.join(
        dir.path,
        '${p.basenameWithoutExtension(path)}.${format.name}',
      );
      await File(outPath).writeAsBytes(encoded);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(outPath)]));
    } catch (_) {
      if (mounted) _showMessage(l10n.detailExportFailed);
    }
  }

  /// Crop/rotate run locally; AI Touch Up goes out to the user's AI vendor.
  /// All three land as a *new* library item ([createDerivedAsset]) — the
  /// photo being edited, and whatever is already backed up under its key,
  /// stays as it is.
  Future<void> _showEditMenu() async {
    final l10n = AppLocalizations.of(context)!;
    if (_records[_index].countsAsVideo) {
      _showMessage(l10n.detailEditVideoUnsupported);
      return;
    }
    final choice = await showCupertinoModalPopup<_EditChoice>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(_EditChoice.crop),
            child: Text(l10n.detailEditCropOption),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(_EditChoice.rotate),
            child: Text(l10n.detailEditRotateOption),
          ),
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(_EditChoice.aiTouchUp),
            child: Text(l10n.detailEditAiOption),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case _EditChoice.crop:
        await _runLocalEdit(PhotoEditMode.crop);
      case _EditChoice.rotate:
        await _runLocalEdit(PhotoEditMode.rotate);
      case _EditChoice.aiTouchUp:
        await _runAiTouchUp();
    }
  }

  Future<void> _runLocalEdit(PhotoEditMode mode) async {
    final l10n = AppLocalizations.of(context)!;
    final record = _records[_index];
    final path = await _resolvePath(record);
    if (!mounted) return;
    if (path == null) {
      _showMessage(l10n.detailFileUnavailable);
      return;
    }
    final edited = await Navigator.of(context).push<Uint8List>(
      CupertinoPageRoute(
        builder: (_) => PhotoEditScreen(file: File(path), mode: mode),
      ),
    );
    if (edited == null || !mounted) return;
    try {
      final created = await createDerivedAsset(
        source: record,
        bytes: edited,
        extension: p.extension(path),
        store: widget.assetRecordStore,
        personStore: _personStore,
      );
      if (!mounted) return;
      _showEdited(created);
      _showMessage(l10n.editSavedAsCopy);
    } catch (_) {
      if (mounted) _showMessage(l10n.editFailed);
    }
  }

  /// Swipes to the freshly created photo, so the edit is what's on screen.
  void _showEdited(AssetRecord created) {
    setState(() {
      _records = [..._records]..insert(_index + 1, created);
    });
    _pageController.animateToPage(
      _index + 1,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  Future<void> _runAiTouchUp() async {
    final l10n = AppLocalizations.of(context)!;
    final record = _records[_index];
    final path = await _resolvePath(record);
    if (!mounted) return;
    if (path == null) {
      _showMessage(l10n.detailFileUnavailable);
      return;
    }
    final prompt = await _askAiPrompt();
    if (prompt == null || prompt.isEmpty || !mounted) return;
    final created = await AiTouchUpQueue.instance.submit(
      source: record,
      file: File(path),
      prompt: prompt,
      store: widget.assetRecordStore,
      personStore: _personStore,
    );
    if (!mounted) return;
    if (created == null) {
      _showMessage(
        l10n.aiTouchUpFailed(AiTouchUpQueue.instance.lastError ?? ''),
      );
      return;
    }
    _showEdited(created);
    _showMessage(l10n.aiTouchUpDone);
  }

  Future<String?> _askAiPrompt() async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController();
    final prompt = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => CupertinoAlertDialog(
          title: Text(l10n.aiTouchUpTitle),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              CupertinoTextField(
                controller: controller,
                autofocus: true,
                maxLines: 3,
                minLines: 2,
                placeholder: l10n.aiTouchUpPromptPlaceholder,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.aiTouchUpNote,
                style: const TextStyle(fontSize: 12),
                textAlign: TextAlign.start,
              ),
            ],
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.actionCancel),
            ),
            CupertinoDialogAction(
              onPressed: controller.text.trim().isEmpty
                  ? null
                  : () => Navigator.of(context).pop(controller.text.trim()),
              child: Text(l10n.aiTouchUpStart),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return prompt;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<double?>(
      valueListenable: _pull,
      builder: (context, pull, child) => CupertinoPageScaffold(
        // The backdrop clears as the photo is pulled off it, so what the
        // photo is going back to is there underneath rather than appearing
        // once it's gone.
        backgroundColor: _screenBackground.withValues(alpha: 1 - (pull ?? 0)),
        // The keyboard must not relayout the page under it. Resizing
        // shrinks the full-height media sliver, which drags the photo and
        // everything under it upward the moment a caption field takes
        // focus — the field scrolls into view on its own (see the info
        // panel's keyboard padding), so nothing here needs to move.
        resizeToAvoidBottomInset: false,
        child: child!,
      ),
      child: SafeArea(
        child: Column(
          children: [
            _ChromeFade(
              pull: _pull,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        l10n.detailDoneButton,
                        style: const TextStyle(color: CupertinoColors.white),
                      ),
                    ),
                    AnimatedBuilder(
                      animation: AiTouchUpQueue.instance,
                      builder: (context, child) =>
                          AiTouchUpQueue.instance.isRunning(
                            _records[_index].localId,
                          )
                          ? Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Row(
                                children: [
                                  const CupertinoActivityIndicator(
                                    color: CupertinoColors.white,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    l10n.aiTouchUpWorking,
                                    style: const TextStyle(
                                      color: CupertinoColors.white,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : child!,
                      child: CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: _showEditMenu,
                        child: Text(
                          l10n.detailEditButton,
                          style: const TextStyle(color: CupertinoColors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _records.length,
                // A zoomed photo owns every drag on it. Panning around
                // one and swiping to the next are the same gesture, and
                // the pager wins that fight by default — which made a
                // zoomed photo impossible to look around.
                // A zoomed photo, or one being pulled down, owns every
                // drag on it: one drag, one meaning.
                physics: _zoomed || _pulling
                    ? const NeverScrollableScrollPhysics()
                    : null,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => _MediaPage(
                  record: _records[i],
                  onPull: _onPull,
                  onPullMayStart: _onPullMayStart,

                  albumStore: widget.albumStore,
                  resolveFile: widget.resolvePhotoManagerFile,
                  resolveLiveVideo: widget.resolveLivePhotoVideo,
                  motionPlayback: _motionPlayback,
                  resolvePlaceName: widget.resolvePlaceName,
                  restoreOriginal: widget.restoreOriginal,
                  restoreThumbnail: widget.restoreThumbnail,
                  onDeviceAnalysis: widget.onDeviceAnalysis,
                  aiVisionService: widget.aiVisionService,
                  assetRecordStore: widget.assetRecordStore,
                  personStore: _personStore,
                  onRecordChanged: _updateRecord,
                  scrollController: _scrollControllerFor(_records[i]),
                  onZoomChanged: (zoomed) {
                    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
                  },
                ),
              ),
            ),
            _ChromeFade(
              pull: _pull,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: _showShareSheet,
                      child: const Icon(
                        CupertinoIcons.share,
                        color: CupertinoColors.white,
                      ),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: _toggleFavorite,
                      child: Icon(
                        _records[_index].isFavorite
                            ? CupertinoIcons.heart_fill
                            : CupertinoIcons.heart,
                        color: CupertinoColors.white,
                      ),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: _revealInfoPanel,
                      child: const Icon(
                        CupertinoIcons.info_circle,
                        color: CupertinoColors.white,
                      ),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: _delete,
                      child: const Icon(
                        CupertinoIcons.trash,
                        color: CupertinoColors.white,
                      ),
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

/// The toolbars get out of the way while the photo is being dragged —
/// they belong to the screen, and the screen is on its way out. Quick, so
/// they're gone by the time the photo has moved any real distance rather
/// than trailing it down the page.
class _ChromeFade extends StatelessWidget {
  const _ChromeFade({required this.pull, required this.child});

  final ValueListenable<double?> pull;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double?>(
      valueListenable: pull,
      child: child,
      builder: (context, progress, child) {
        final opacity = (1 - (progress ?? 0) * 5).clamp(0.0, 1.0);
        if (opacity == 1) return child!;
        return IgnorePointer(
          ignoring: opacity == 0,
          child: Opacity(opacity: opacity, child: child),
        );
      },
    );
  }
}

class _MediaPage extends StatefulWidget {
  const _MediaPage({
    required this.record,
    required this.assetRecordStore,
    required this.personStore,
    required this.onRecordChanged,
    required this.scrollController,
    required this.albumStore,
    required this.onPull,
    required this.onPullMayStart,
    required this.onZoomChanged,
    required this.motionPlayback,
    this.onDeviceAnalysis,
    this.aiVisionService,
    this.resolveFile,
    this.resolveLiveVideo,
    this.resolvePlaceName,
    this.restoreOriginal,
    this.restoreThumbnail,
  });

  final AssetRecord record;
  final Future<File?> Function(AssetRecord record)? resolveFile;

  /// See [DetailScreen.resolveLivePhotoVideo].
  final Future<File?> Function(AssetRecord record)? resolveLiveVideo;

  /// See [DetailScreen.resolvePlaceName].
  final Future<String?> Function(AssetRecord record)? resolvePlaceName;
  final AssetRecordStore assetRecordStore;
  final PersonStore personStore;
  final AlbumStore? albumStore;
  final ValueChanged<AssetRecord> onRecordChanged;

  /// Re-downloads a cloud-only asset's original ([AssetRecord.localDeleted])
  /// and returns its new local path. Defaults to a real [OriginalRestore];
  /// overridable for tests so they never make a network call.
  final Future<String?> Function(AssetRecord record)? restoreOriginal;

  /// Re-downloads just the small `thumbnails/` object — see
  /// [OriginalRestore.restoreThumbnail]. Same defaulting and the same
  /// reason for being injectable.
  final Future<String?> Function(AssetRecord record)? restoreThumbnail;

  /// Owned by `_DetailScreenState` — the info-circle button in the bottom
  /// bar drives it directly, so this page's `CustomScrollView` just needs
  /// to use it.
  final ScrollController scrollController;

  /// How far the photo has been pulled down, 0 to 1, or `null` when it
  /// isn't being pulled. The pager stands down while it is, and the chrome
  /// fades out of the way of what's being dragged.
  final ValueChanged<double?> onPull;

  /// A pull is now possible, or is no longer possible — which is the cue to
  /// uncover what is behind the photo, ahead of anyone dragging it. Separate
  /// from [onPull] because it fires on a touch that may still turn out to be
  /// a tap, and nothing about the photo itself moves for it.
  final ValueChanged<bool> onPullMayStart;

  /// Tells the pager this page is zoomed, so it stops taking the drags that
  /// are meant to move the photo around.
  final ValueChanged<bool> onZoomChanged;

  /// See [DetailScreen.onDeviceAnalysis].
  final OnDeviceAnalysisService? onDeviceAnalysis;
  final AiVisionService? aiVisionService;

  /// How Live Photos and GIFs behave, shared by every page in the pager
  /// and remembered between launches.
  final MotionPlaybackSetting motionPlayback;

  @override
  State<_MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<_MediaPage>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _videoController;
  Object? _error;

  /// Whether the Live Photo / GIF is moving right now — lights the badge.
  bool _motionPlaying = false;

  /// `photoManager` records carry no `sourcePath` — it's resolved on demand
  /// here via `photo_manager`, same as the library grid does. `null` while
  /// still resolving; stays `null` for good if the asset's gone from the
  /// library or was never resolvable.
  String? _path;
  bool _resolvingPath = false;

  bool _dismissed = false;

  /// Drag the photo down and it comes with the finger — sideways too — and
  /// goes back to the grid when let go of far enough down. Let go of it
  /// short of that and it springs back. Same as real Photos, and the same
  /// bargain: the first direction decides what the drag means. Sideways is
  /// the pager's; downward from the top of the page is the photo's.
  ///
  /// Read straight off the pointer rather than off the scroll view's
  /// overscroll, because that reading was never really about the pull: the
  /// pager and the scroll view both watch for a drag, Flutter's drag
  /// recognisers measure the *length of the path* travelled rather than
  /// its direction, so the two tie on anything diagonal — and the pager
  /// took the tie. Only a pull whose sideways component was exactly zero
  /// ever reached the scroll view.
  ///
  /// Settling that fight by giving the pager a longer threshold doesn't
  /// work: the two accumulate at the same rate, so *any* consistent lean,
  /// even a few degrees, would go to the page instead of the pager and
  /// swiping between photos would stop working. So the fight is left alone
  /// and the drag is read from the pointer, outside the arena, where the
  /// only question that matters can be asked directly: did this go down
  /// far enough, and more down than sideways?
  static const _dragStartDistance = 24.0;

  /// Past this, letting go dismisses; short of it, the photo springs back.
  static const _dismissPullDistance = 64.0;

  /// A flick lets go early — the photo is already on its way out, and
  /// holding it to the full distance would feel like it caught on
  /// something.
  static const _dismissFlickVelocity = 700.0;
  static const _dismissFlickDistance = 40.0;

  /// How much of the drag is allowed to be sideways. A thumb pulling down
  /// swings through an arc, so demanding it go down further than it goes
  /// across ruled out most real pulls; at 0.7 anything steeper than about
  /// 35 degrees off horizontal counts, which still leaves a swipe to the
  /// next photo unmistakable.
  static const _dismissPullLean = 0.7;

  /// The distance over which the photo shrinks and the backdrop clears.
  /// Longer than the dismiss threshold on purpose: the photo should still
  /// be growing smaller in the hand well past the point of no return.
  static const _dragVisualRun = 240.0;

  int _pointers = 0;

  /// Where the downward part of this gesture began — not where the finger
  /// landed. Re-anchored (see [_onPointerMove]) for as long as the finger
  /// isn't going down, so a pull that starts part-way through a sideways
  /// swipe is measured from the turn rather than from the start.
  Offset? _pullOrigin;
  VelocityTracker? _velocity;

  /// Where the photo currently sits under the finger. A notifier, not
  /// state: only the transform around the page needs to rebuild per frame,
  /// not the page (and its info panel) inside it.
  final ValueNotifier<Offset> _drag = ValueNotifier(Offset.zero);

  /// True once the drag has been claimed — the pager and the scroll view
  /// both stand down for the rest of it.
  bool _dragging = false;

  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );
  Animation<Offset>? _settleTween;

  /// Only from the top of the page: further down, a drag downward is the
  /// info panel being put back, not the photo being let go of.
  bool get _atTop {
    final controller = widget.scrollController;
    return !controller.hasClients || controller.position.pixels <= 0;
  }

  double _progressOf(Offset drag) => (drag.dy / _dragVisualRun).clamp(0.0, 1.0);

  void _onPointerDown(PointerDownEvent event) {
    _pointers++;
    // A second finger means a pinch — nobody dismisses a photo with two.
    if (_pointers > 1 || _zoomed || !_atTop) {
      _pullOrigin = null;
      return;
    }
    _settle.stop();
    _pullOrigin = event.position;
    _velocity = VelocityTracker.withKind(event.kind);
    // Ask for the grid behind now, while the finger is still deciding what
    // this gesture is. Uncovering the route below is a first paint of the
    // whole library grid, and doing it at the moment the drag is claimed
    // put that paint in the first frame of the pull — the one frame the
    // gesture is judged on. Asked for here it lands during the touch, with
    // nothing moving yet. Put back in [_onPointerDone] if this turns out
    // to have been a tap or a swipe.
    widget.onPullMayStart(true);
  }

  void _onPointerMove(PointerMoveEvent event) {
    var origin = _pullOrigin;
    if (origin == null || _dismissed) return;
    _velocity?.addPosition(event.timeStamp, event.position);
    if (!_dragging) {
      // The anchor follows the finger back up to the highest point it has
      // reached. A swipe sideways holds its height, so it re-anchors every
      // frame and never accumulates a sideways component to be measured
      // against; the moment the finger turns downward, the pull is read
      // from there. Without this, an L — swipe to the next photo, then
      // pull it down — could never satisfy the lean test, because the
      // sideways run was still counted against the downward one.
      if (event.position.dy <= origin.dy) {
        _pullOrigin = origin = event.position;
        return;
      }
    }
    final moved = event.position - origin;
    if (!_dragging) {
      if (moved.dy < _dragStartDistance ||
          moved.dy <= moved.dx.abs() * _dismissPullLean) {
        return;
      }
      if (!_atTop) {
        _pullOrigin = null;
        return;
      }
      // End the scroll view's own drag rather than yanking the physics out
      // from under it. Swapping to [NeverScrollableScrollPhysics] replaces
      // the position mid-gesture, so the drag it had started never ends
      // and never says so — and whoever is listening for the end of a
      // scroll (the app-wide `ScrollStopGuard`) waits for a notification
      // that is never coming. `jumpTo` where it already is stops the
      // activity and posts the end.
      final position = widget.scrollController.hasClients
          ? widget.scrollController.position
          : null;
      position?.jumpTo(position.pixels);
      setState(() => _dragging = true);
    }
    // The distance it took to claim the drag comes back off, so the photo
    // doesn't jump out from under the finger the moment it's picked up.
    _setDrag(moved - const Offset(0, _dragStartDistance));
  }

  void _onPointerDone(PointerEvent event) {
    if (_pointers > 0) _pointers--;
    _pullOrigin = null;
    // Only the pull itself keeps the grid behind visible past this point.
    if (!_dragging) widget.onPullMayStart(false);
    final velocity = _velocity?.getVelocity().pixelsPerSecond ?? Offset.zero;
    _velocity = null;
    if (!_dragging || _dismissed) return;
    final pulled = _drag.value.dy + _dragStartDistance;
    final flicked =
        velocity.dy > _dismissFlickVelocity && pulled > _dismissFlickDistance;
    if (pulled >= _dismissPullDistance || flicked) {
      // Carried on in the direction it was thrown while the route fades,
      // rather than hanging where the finger left it. A photo that stops
      // dead and then dissolves reads as the app thinking about it; one
      // that keeps going reads as gone the moment it was let go of.
      _dismissed = true;
      _carryOn(velocity.dy);
      Navigator.of(context).pop();
      return;
    }
    _springBack();
  }

  void _setDrag(Offset value) {
    _drag.value = value;
    widget.onPull(_progressOf(value));
  }

  /// The last of the gesture, run out over the route's own fade: down by
  /// a little, or by a lot if it was flicked.
  void _carryOn(double velocity) {
    _settle.duration = const Duration(milliseconds: 140);
    _settleTween = Tween<Offset>(
      begin: _drag.value,
      end: _drag.value + Offset(0, (velocity * 0.12).clamp(40.0, 180.0)),
    ).animate(CurvedAnimation(parent: _settle, curve: Curves.easeOutCubic));
    _settle
      ..value = 0
      ..forward();
  }

  void _springBack() {
    _settle.duration = const Duration(milliseconds: 240);
    _settleTween = Tween<Offset>(
      begin: _drag.value,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _settle, curve: Curves.easeOutCubic));
    _settle
      ..value = 0
      ..forward();
  }

  void _onSettleTick() {
    final tween = _settleTween;
    if (tween != null) _setDrag(tween.value);
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // A photo on its way out has nothing to put back: the page is going
    // with the route, and rebuilding it to un-drag it only puts the
    // stand-in back under a photo that is already fading.
    if (_dismissed) return;
    _settleTween = null;
    if (mounted) setState(() => _dragging = false);
    widget.onPull(null);
  }

  /// True while the photo is zoomed in. Everything that scrolls has to
  /// stand down: panning a zoomed photo is the same drag as swiping to the
  /// next one, or as dragging the info panel up.
  bool _zoomed = false;

  void _onZoomChanged(bool zoomed) {
    if (zoomed == _zoomed) return;
    setState(() => _zoomed = zoomed);
    widget.onZoomChanged(zoomed);
  }

  /// Starts from the record and flips false once [_restoreOriginal] has
  /// pulled the full-resolution copy back down.
  late bool _localDeleted = widget.record.localDeleted;
  bool _restoring = false;

  /// A thumbnail fetched back out of the bucket, and whether that has been
  /// tried — see [_fetchThumbnail].
  String? _thumbnailPath;
  bool _fetchedThumbnail = false;

  @override
  void initState() {
    super.initState();
    _settle
      ..addListener(_onSettleTick)
      ..addStatusListener(_onSettleStatus);
    // Cloud-only: nothing local to resolve, and `sourcePath` still points
    // at the deleted file. The cached thumbnail carries the page until the
    // user asks for the original back.
    if (_localDeleted) return;
    final direct = widget.record.sourcePath;
    if (direct != null) {
      _path = direct;
      _initVideoIfNeeded();
    } else if (widget.record.sourceType == AssetSourceType.photoManager) {
      // Set directly rather than via setState: this runs synchronously
      // during initState, before the first build, so the field's starting
      // value is picked up without needing to mark the tree dirty.
      _resolvingPath = true;
      _resolvePath();
    }
  }

  Future<void> _resolvePath() async {
    final resolver = widget.resolveFile ?? PhotoLibraryService.resolveFile;
    File? file;
    try {
      file = await resolver(widget.record);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _resolvingPath = false;
      _path = file?.path;
    });
    _initVideoIfNeeded();
  }

  void _initVideoIfNeeded() {
    final path = _path;
    if (path == null || !widget.record.isVideo) return;
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

  @override
  void dispose() {
    _videoController?.dispose();
    _settle.dispose();
    _drag.dispose();
    super.dispose();
  }

  /// The bucket's thumbnail object, pulled down once for a cloud-only
  /// photo that has no local picture of itself left.
  ///
  /// Once per page, whatever the answer: a photo small enough that its
  /// thumbnail upload was skipped has nothing up there to fetch, and
  /// re-asking on every rebuild would be a request per frame.
  Future<void> _fetchThumbnail() async {
    if (_fetchedThumbnail) return;
    _fetchedThumbnail = true;
    final restore =
        widget.restoreThumbnail ??
        (record) => OriginalRestore(
          targetsStore: BackupTargetsStore(),
          recordStore: widget.assetRecordStore,
        ).restoreThumbnail(record);
    String? path;
    try {
      path = await restore(widget.record);
    } catch (_) {
      path = null;
    }
    if (path == null || !mounted) return;
    setState(() => _thumbnailPath = path);
    widget.onRecordChanged(widget.record.withThumbnailPath(path));
  }

  Future<void> _restoreOriginal() async {
    final restore =
        widget.restoreOriginal ??
        (record) => OriginalRestore(
          targetsStore: BackupTargetsStore(),
          recordStore: widget.assetRecordStore,
        ).restore(record);
    setState(() => _restoring = true);
    String? restored;
    try {
      restored = await restore(widget.record);
    } catch (_) {
      restored = null;
    }
    if (!mounted) return;
    setState(() {
      _restoring = false;
      if (restored != null) {
        _path = restored;
        _localDeleted = false;
      }
    });
    if (restored == null) return;
    widget.onRecordChanged(
      widget.record
          .withSourcePath(restored, DateTime.now())
          .withLocalDeleted(false),
    );
    _initVideoIfNeeded();
  }

  /// The cached thumbnail, plus the offer to pull the full-resolution copy
  /// back down from the bucket — what a cloud-only asset shows instead of
  /// its (deleted) original.
  ///
  /// With no thumbnail to draw either, the bucket's own `thumbnails/` copy
  /// is fetched once (see [_fetchThumbnail]) — it is a few kilobytes, and
  /// the alternative is a grey triangle where a picture should be. Only
  /// when even that comes back with nothing does it say what is actually
  /// true — the bucket still has it — rather than "no longer available",
  /// which is the one thing this state is not, and read as a contradiction
  /// next to a Download button and a row saying Backed Up.
  Widget _cloudOnly(AppLocalizations l10n) {
    final thumbnail = _thumbnailPath ?? widget.record.thumbnailPath;
    if (thumbnail == null) unawaited(_fetchThumbnail());
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumbnail != null)
          // Not wrapped in a `Center`: that hands the image loose
          // constraints, so it draws at the thumbnail's own 320px in the
          // middle of the screen and `contain` has nothing to fit. As the
          // stack's own child it gets tight ones and fills the screen —
          // blurry, but a blurry photo you can see beats a sharp stamp of
          // one you can't.
          Image.file(
            File(thumbnail),
            fit: BoxFit.contain,
            // A 4x upscale through the default bilinear filter is visibly
            // blocky; this costs one static image, not a scrolling grid.
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stackTrace) {
              unawaited(_fetchThumbnail());
              return _MissingFileNote(message: l10n.detailCloudOnlyNote);
            },
          )
        else
          _MissingFileNote(message: l10n.detailCloudOnlyNote),
      ],
    );
  }

  /// The photo, with the cached thumbnail held underneath it until the
  /// full-size file has painted.
  ///
  /// Underneath, not cross-faded against: two half-transparent copies of
  /// the same picture composited over black come out *dimmer* than either
  /// of them, so a cross-fade between a photo and itself reads as a flash
  /// in the middle of it. The stand-in simply stays put and the real photo
  /// arrives on top of it.
  /// Always the same two-child stack, even when there is no stand-in to
  /// draw. Collapsing to the content alone changes the tree's shape, and
  /// the `InteractiveViewer` underneath is then rebuilt from scratch
  /// rather than matched — which threw away the zoom at the exact moment
  /// the stand-in went, i.e. on zooming in.
  Widget _media(AppLocalizations l10n) => Stack(
    fit: StackFit.expand,
    children: [_standIn() ?? const SizedBox.shrink(), _mediaContent(l10n)],
  );

  /// The same picture the grid was just showing, screen-sized and
  /// *contained* — drawn cover, the stand-in is cropped differently from
  /// the photo that replaces it, so the swap reads as a jump rather than a
  /// photo sharpening.
  ///
  /// `fittedThumbnail` is what makes that true of the pixels and not just
  /// of the `BoxFit`: the OS hands back a centre-cropped square otherwise,
  /// and a square drawn `contain` under a photo drawn `contain` is the
  /// flash — the picture arrives, then re-frames.
  ///
  /// Only for stills: a video's controls sit under the frame, and a
  /// thumbnail behind those is a thumbnail showing through them.
  Widget? _standIn() {
    if (widget.record.isVideo || _localDeleted || _error != null) return null;
    // Not while the photo is being dragged: by then the real one has
    // certainly painted, and a second full-screen image under it is one
    // more screen of pixels for the GPU to sample on every frame of a
    // gesture that has to keep up with a finger.
    if (_dragging) return null;
    // Nor once it has been zoomed. The stand-in doesn't zoom or pan with
    // the photo — it is a separate widget outside the InteractiveViewer —
    // so panning a zoomed photo slid the real one off its stand-in and
    // showed both at once, one letterboxed behind the other. The same
    // "it has certainly painted by now" applies: nobody zooms a photo
    // that isn't up yet.
    if (_zoomed) return null;
    return Center(
      child: assetImage(
        widget.record,
        fit: BoxFit.contain,
        thumbnailSize: 1200,
        fittedThumbnail: true,
        placeholder: () => const ColoredBox(color: CupertinoColors.black),
      ),
    );
  }

  Widget _mediaContent(AppLocalizations l10n) {
    if (_localDeleted) return _cloudOnly(l10n);
    final path = _path;
    if (path == null) {
      // The stand-in behind this is already showing the photo — see
      // [_standIn]. Anything drawn here would be drawn on top of it.
      if (_resolvingPath) return const SizedBox.shrink();
      return _MissingFileNote(message: l10n.detailFileUnavailable);
    }
    if (_error != null) {
      return _MissingFileNote(message: l10n.detailFileUnavailable);
    }
    final controller = _videoController;
    if (controller != null) {
      if (!controller.value.isInitialized) {
        return const Center(
          child: CupertinoActivityIndicator(color: CupertinoColors.white),
        );
      }
      return Column(
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: GestureDetector(
                  onTap: () => setState(() {
                    controller.value.isPlaying
                        ? controller.pause()
                        : controller.play();
                  }),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      VideoPlayer(controller),
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: controller,
                        builder: (context, value, _) => value.isPlaying
                            ? const SizedBox.shrink()
                            : const Icon(
                                CupertinoIcons.play_circle,
                                size: 64,
                                color: CupertinoColors.white,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          VideoControls(controller: controller),
        ],
      );
    }
    errorBuilder(BuildContext context, Object error, StackTrace? stack) =>
        _MissingFileNote(message: l10n.detailFileUnavailable);

    // A GIF is the only still this app draws that moves on its own, so it
    // gets the animation itself rather than a plain `Image` — see
    // `gif_view.dart` for why stopping one takes two widgets.
    if (widget.record.isGif) {
      return _motion(
        label: l10n.detailGifBadge,
        icon: CupertinoIcons.photo_on_rectangle,
        child: (mode) => _ZoomableImage(
          onZoomChanged: _onZoomChanged,
          errorBuilder: errorBuilder,
          file: File(path),
          child: GifView(
            file: File(path),
            mode: mode,
            errorBuilder: errorBuilder,
            onPlayingChanged: _onMotionPlayingChanged,
          ),
        ),
      );
    }

    final still = _ZoomableImage(
      file: File(path),
      onZoomChanged: _onZoomChanged,
      errorBuilder: errorBuilder,
    );
    if (!widget.record.isLivePhoto) return still;
    return _motion(
      label: l10n.detailLivePhotoBadge,
      icon: CupertinoIcons.smallcircle_circle,
      child: (mode) => LivePhotoView(
        still: still,
        mode: mode,
        onPlayingChanged: _onMotionPlayingChanged,
        resolveVideo: () =>
            (widget.resolveLiveVideo ??
            PhotoLibraryService.resolveLivePhotoVideo)(widget.record),
      ),
    );
  }

  /// A moving picture plus the two things that belong over one: the badge
  /// saying what it is, and the three buttons saying how it should behave.
  Widget _motion({
    required String label,
    required IconData icon,
    required Widget Function(MotionPlayMode mode) child,
  }) {
    final setting = widget.motionPlayback;
    return ValueListenableBuilder<MotionPlayMode>(
      valueListenable: setting.mode,
      builder: (context, mode, _) => Stack(
        fit: StackFit.expand,
        children: [
          child(mode),
          Positioned(
            top: 12,
            left: 12,
            child: MotionBadge(
              label: label,
              icon: icon,
              active: _motionPlaying,
            ),
          ),
          Positioned(
            top: 10,
            right: 12,
            child: MotionPlayModeBar(mode: mode, onChanged: setting.set),
          ),
        ],
      ),
    );
  }

  void _onMotionPlayingChanged(bool playing) {
    if (!mounted || playing == _motionPlaying) return;
    setState(() => _motionPlaying = playing);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerDone,
      onPointerCancel: _onPointerDone,
      child: ValueListenableBuilder<Offset>(
        valueListenable: _drag,
        // The photo follows the finger and shrinks as it goes — the
        // shrinking is what says "this is leaving" while it's still in
        // hand and can still be put back.
        builder: (context, drag, child) => drag == Offset.zero
            ? child!
            : Transform.translate(
                offset: drag,
                child: Transform.scale(
                  scale: 1 - 0.3 * _progressOf(drag),
                  // Inside the transform on purpose: the page is painted
                  // once into its own layer and the drag then moves and
                  // scales that layer, rather than repainting a
                  // full-screen photo sixty times a second.
                  child: RepaintBoundary(child: child),
                ),
              ),
        child: LayoutBuilder(
          builder: (context, constraints) => CustomScrollView(
            controller: widget.scrollController,
            physics: _zoomed || _dragging
                ? const NeverScrollableScrollPhysics()
                : const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: SizedBox(
                  height: constraints.maxHeight,
                  child: _media(l10n),
                ),
              ),
              SliverToBoxAdapter(
                child: _InfoPanel(
                  record: widget.record,
                  cloudOnly: _localDeleted,
                  restoring: _restoring,
                  onRestoreOriginal: _restoreOriginal,
                  onDeviceAnalysis: widget.onDeviceAnalysis,
                  aiVisionService: widget.aiVisionService,
                  resolvePlaceName: widget.resolvePlaceName,
                  resolvedPath: _path,
                  videoController: _videoController,
                  assetRecordStore: widget.assetRecordStore,
                  personStore: widget.personStore,
                  albumStore: widget.albumStore,
                  onRecordChanged: widget.onRecordChanged,
                ),
              ),
            ],
          ),
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
          const Icon(
            CupertinoIcons.exclamationmark_triangle,
            size: 48,
            color: CupertinoColors.systemGrey,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: const TextStyle(color: CupertinoColors.systemGrey),
          ),
        ],
      ),
    );
  }
}

/// Pinch (via [InteractiveViewer]) and double-tap to zoom, same as Photos —
/// double-tap zooms in centered on the tap point, or back out if already
/// zoomed. `panEnabled` tracks the current scale rather than staying on:
/// left on permanently, dragging while unzoomed would fight the page's own
/// pull-down-to-dismiss gesture on [_MediaPage]'s `CustomScrollView`.
class _ZoomableImage extends StatefulWidget {
  const _ZoomableImage({
    required this.file,
    required this.errorBuilder,
    this.onZoomChanged,
    this.child,
  });

  final File file;
  final ImageErrorWidgetBuilder errorBuilder;

  /// Drawn instead of a plain `Image` of [file] — a GIF, which needs its
  /// own widget to be stoppable. Zooming and double-tap work the same
  /// either way.
  final Widget? child;

  /// Fires when the photo becomes zoomed, or stops being. Everything that
  /// scrolls around this image has to get out of the way while it is:
  /// a pan on a zoomed photo and a swipe to the next one are the same
  /// gesture, and the pager wins it.
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage>
    with SingleTickerProviderStateMixin {
  static const _zoomedScale = 3.0;

  final _transformation = TransformationController();
  late final AnimationController _animController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  Animation<Matrix4>? _animation;
  Offset _doubleTapPosition = Offset.zero;
  bool _reportedZoom = false;

  bool get _isZoomed => _transformation.value.getMaxScaleOnAxis() > 1.01;

  static int _decodeWidth(BuildContext context) =>
      (MediaQuery.sizeOf(context).width *
              MediaQuery.devicePixelRatioOf(context))
          .round();

  @override
  void initState() {
    super.initState();
    _transformation.addListener(_onTransformChanged);
    _animController.addListener(() {
      final animation = _animation;
      if (animation != null) _transformation.value = animation.value;
    });
  }

  /// Watches the transform itself rather than gesture callbacks, so a
  /// double-tap zoom (which animates) counts the same as a pinch.
  void _onTransformChanged() {
    final zoomed = _isZoomed;
    if (zoomed == _reportedZoom) return;
    setState(() => _reportedZoom = zoomed);
    widget.onZoomChanged?.call(zoomed);
  }

  @override
  void dispose() {
    _transformation.removeListener(_onTransformChanged);
    _animController.dispose();
    _transformation.dispose();
    super.dispose();
  }

  void _onDoubleTap() {
    final end = _isZoomed
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(
              -_doubleTapPosition.dx * (_zoomedScale - 1),
              -_doubleTapPosition.dy * (_zoomedScale - 1),
              0,
              1,
            )
            ..scaleByDouble(_zoomedScale, _zoomedScale, _zoomedScale, 1));
    _animation = Matrix4Tween(
      begin: _transformation.value,
      end: end,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOut));
    _animController.forward(from: 0);
  }

  /// The photo, screen-sized, with the full-resolution copy laid *over* it
  /// once it is zoomed into — never in place of it.
  ///
  /// Swapping one `Image`'s `cacheWidth` was the obvious way to do this and
  /// is the flash on the first double-tap: a different `cacheWidth` is a
  /// different image key, so the decoded picture is thrown away, the new
  /// decode starts from disk, and the `frameBuilder` has nothing to draw in
  /// between — several frames of black, right in the middle of the zoom.
  /// Two images means the screen-sized one is still there to be looked at
  /// while the sharp one decodes, and the sharpening is all you see.
  Widget _still(BuildContext context) {
    final screenSized = _file(width: _decodeWidth(context));
    if (!_isZoomed) return screenSized;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        screenSized,
        Positioned.fill(child: _file(width: null)),
      ],
    );
  }

  /// [width] null is the sensor's own resolution. Otherwise decoded to the
  /// screen: a 12 MP photo is a 48 MB texture, and drawn into a
  /// 1170-pixel-wide phone it is the same picture at an eighth of the cost.
  /// The big one exists only while zoomed, and goes when the zoom does.
  Widget _file({required int? width}) => Image.file(
    widget.file,
    fit: BoxFit.contain,
    cacheWidth: width,
    errorBuilder: widget.errorBuilder,
    // Already decoded (a photo swiped back to) paints at once; anything
    // else comes up over what is behind it rather than appearing between
    // two frames.
    frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
        wasSynchronouslyLoaded
        ? child
        : AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            child: child,
          ),
  );

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
      onDoubleTap: _onDoubleTap,
      child: InteractiveViewer(
        transformationController: _transformation,
        minScale: 1,
        maxScale: _zoomedScale,
        panEnabled: _isZoomed,
        child: Center(child: widget.child ?? _still(context)),
      ),
    );
  }
}

/// The "swipe/scroll up for details" panel real Photos shows below the
/// image — date/time header, then a plain list of file facts, then
/// Description/Tags/People. Date/time, location, description, tags, and
/// tagged people are all editable in place.
class _InfoPanel extends StatefulWidget {
  const _InfoPanel({
    required this.record,
    required this.cloudOnly,
    required this.restoring,
    required this.onRestoreOriginal,
    required this.onDeviceAnalysis,
    required this.aiVisionService,
    required this.resolvePlaceName,
    required this.resolvedPath,
    required this.videoController,
    required this.assetRecordStore,
    required this.personStore,
    required this.albumStore,
    required this.onRecordChanged,
  });

  final AssetRecord record;

  /// Whether the original is gone and only the bucket has it. Read from
  /// `_MediaPage` rather than [record] because a restore that has just
  /// landed hasn't reached the record yet.
  final bool cloudOnly;
  final bool restoring;
  final VoidCallback onRestoreOriginal;

  /// Same value `_MediaPage` resolved and rendered — `photoManager` records
  /// have no `record.sourcePath` of their own.
  final String? resolvedPath;

  /// See [DetailScreen.resolvePlaceName].
  final Future<String?> Function(AssetRecord record)? resolvePlaceName;

  /// See [DetailScreen.onDeviceAnalysis].
  final OnDeviceAnalysisService? onDeviceAnalysis;
  final AiVisionService? aiVisionService;

  final VideoPlayerController? videoController;
  final AssetRecordStore assetRecordStore;
  final PersonStore personStore;

  /// Optional: the viewer opens from places with no album store of their own
  /// (a person's page, a smart collection), and this is the only section
  /// that needs one.
  final AlbumStore? albumStore;
  final ValueChanged<AssetRecord> onRecordChanged;

  @override
  State<_InfoPanel> createState() => _InfoPanelState();
}

class _InfoPanelState extends State<_InfoPanel> {
  int? _bytes;
  int? _width;
  int? _height;
  List<Person> _people = const [];
  late final TextEditingController _description = TextEditingController(
    text: widget.record.description,
  );

  @override
  void initState() {
    super.initState();
    _load();
    _loadPeopleThenFaces();
    _loadAlbums();
    _loadSuggestion();
    _fillLocationFromMetadata();
  }

  /// Faces come after the people: whether to show them at all depends on
  /// whether anyone here is already named (see [_loadFoundFaces]).
  Future<void> _loadPeopleThenFaces() async {
    await _loadPeople();
    await _loadFoundFaces();
  }

  @override
  void didUpdateWidget(_InfoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // `resolvedPath` starts null for `photoManager` records and arrives
    // once `_MediaPage` finishes resolving it — reload when that happens.
    if (oldWidget.resolvedPath != widget.resolvedPath) {
      _load();
      // The path arrives after the panel is built for a camera-roll photo,
      // and there is nothing to cut a face out of until it does.
      _loadFoundFaces();
    }
    if (oldWidget.record.localId != widget.record.localId) {
      _description.text = widget.record.description;
      _faces = const [];
      _faceRects = const [];
      _faceGuesses = const [];
      _loadPeopleThenFaces();
      _loadAlbums();
      _loadSuggestion();
      _fillLocationFromMetadata();
    }
  }

  /// Names the place from the photo's own GPS tag the first time it's
  /// opened, so Places populates itself. Only ever fills an empty field —
  /// see [PhotoLocationService], which is also where the "on view, not in
  /// bulk" reasoning lives.
  Future<void> _fillLocationFromMetadata() async {
    final record = widget.record;
    final existing = record.location;
    if (existing != null && existing.isNotEmpty) return;
    final resolve =
        widget.resolvePlaceName ??
        (AssetRecord r) => PhotoLocationService().placeNameFor(
          r,
          store: widget.assetRecordStore,
        );
    final name = await resolve(record);
    if (name == null || name.isEmpty || !mounted) return;
    // Raced by a hand-typed value while the geocoder was working: theirs wins.
    final current = widget.record.location;
    if (current != null && current.isNotEmpty) return;
    await widget.assetRecordStore.setLocation(record.localId, name);
    if (!mounted) return;
    widget.onRecordChanged(widget.record.withLocation(name));
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  /// What the analyze pass came back with for *this* photo, if nobody has
  /// answered it yet. Asked here rather than collected into a list of its
  /// own: the question is "is this right about this photo?", and only the
  /// photo screen can show the photo it's about.
  AiPhotoAnalysis? _suggestion;

  Future<void> _loadSuggestion() async {
    AiPhotoAnalysis? found;
    try {
      final analysis = await _onDeviceAnalysis.analysisStore.get(
        widget.record.localId,
      );
      if (analysis != null && !analysis.reviewed && analysis.hasSuggestions) {
        found = analysis;
      }
    } catch (_) {
      // No analysis database (a test, a fresh install) — there's simply
      // nothing to answer.
    }
    if (!mounted) return;
    setState(() => _suggestion = found);
  }

  Future<void> _keepSuggestion() async {
    final suggestion = _suggestion;
    if (suggestion == null) return;
    await acceptSuggestion(
      suggestion,
      records: widget.assetRecordStore,
      analyses: _onDeviceAnalysis.analysisStore,
    );
    final updated = await widget.assetRecordStore.getByLocalId(
      widget.record.localId,
    );
    if (!mounted) return;
    setState(() {
      _suggestion = null;
      if (updated != null) _description.text = updated.description;
    });
    if (updated != null) widget.onRecordChanged(updated);
  }

  Future<void> _dropSuggestion() async {
    final suggestion = _suggestion;
    if (suggestion == null) return;
    await dismissSuggestion(
      suggestion.localId,
      analyses: _onDeviceAnalysis.analysisStore,
    );
    if (!mounted) return;
    setState(() => _suggestion = null);
  }

  /// Face thumbnails waiting to be named. The crops themselves aren't
  /// stored — cutting them again costs one decode — but the boxes are, so
  /// a photo the analyze pass has already been over shows its faces the
  /// moment it opens, without looking again.
  List<Uint8List> _faces = const [];

  /// Where each of [_faces] sits in the photo, same order — what makes the
  /// tapped face become *that* person's picture rather than the whole
  /// group shot.
  List<FaceRect> _faceRects = const [];

  /// Who each of [_faces] might be, same order — `null` where the app has
  /// no opinion, which is most of them until somebody has been named a few
  /// times.
  List<String?> _faceGuesses = const [];
  bool _suggesting = false;
  String? _suggestNote;

  late final OnDeviceAnalysisService _onDeviceAnalysis =
      widget.onDeviceAnalysis ??
      OnDeviceAnalysisService(analysisStore: AiAnalysisStore());
  late final AiVisionService _aiVision =
      widget.aiVisionService ?? AiVisionService();

  /// Remembers a face once it's named, and reads back what the analyze
  /// pass guessed. Resolves to the file already open on screen — this
  /// screen never has to go looking for a path.
  late final FaceIdentityService _faceIdentity = FaceIdentityService(
    analysisStore: _onDeviceAnalysis.analysisStore,
    resolvePath: (_) async => widget.resolvedPath,
  );

  /// Looks at this one photo, now, because that's when the user asked. No
  /// sweep over the library: analysis is only worth its battery on the
  /// photo someone is actually looking at, and the paid version is only
  /// worth its money there too.
  Future<void> _suggestOnDevice() async {
    final path = widget.resolvedPath;
    if (path == null) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _suggesting = true;
      _suggestNote = null;
    });
    final found = await _onDeviceAnalysis.analyze(widget.record, path);
    final faces = found.map((f) => f.toPersonFace()).toList();
    final crops = await FaceCrops.of(path, faces);
    if (!mounted) return;
    setState(() {
      _suggesting = false;
      _faces = crops;
      _faceRects = faces.take(crops.length).toList();
      _faceGuesses = List.filled(crops.length, null);
      _suggestNote = crops.isEmpty ? l10n.detailSuggestNothing : null;
    });
    await _loadGuesses();
  }

  /// Puts names to whatever the analyze pass guessed about these faces.
  /// Reads only — the guessing itself is the queue's job, on its own pace.
  Future<void> _loadGuesses() async {
    if (_faceRects.isEmpty) return;
    try {
      final byFace = await _onDeviceAnalysis.analysisStore.suggestionsFor(
        widget.record.localId,
      );
      if (byFace.isEmpty || !mounted) return;
      final names = {
        for (final person in await widget.personStore.listAll())
          person.id: person.name,
      };
      if (!mounted) return;
      setState(() {
        _faceGuesses = [
          for (final rect in _faceRects) names[byFace[rect.encode()]],
        ];
      });
    } catch (_) {
      // No analysis database, or no people — the faces just stay
      // questions, which is what they were.
    }
  }

  /// Shows what the analyze pass already found here, rather than making
  /// the user ask for a scan that has already happened. Reads the stored
  /// boxes and cuts the crops — no Vision call, no cost.
  ///
  /// Skipped once somebody in this photo has a name: iOS won't say whose
  /// face is whose, so the app can't tell which of the boxes is the person
  /// already tagged, and offering them all again is an invitation to tag
  /// the same face twice under two names. Find Faces is still there for
  /// anyone who wants to go through them anyway.
  Future<void> _loadFoundFaces() async {
    final path = widget.resolvedPath;
    if (path == null || _faces.isNotEmpty || _people.isNotEmpty) return;
    final List<FaceRect> stored;
    try {
      stored = await _onDeviceAnalysis.analysisStore.facesFor(
        widget.record.localId,
      );
    } catch (_) {
      // No analysis database (a widget test, a fresh install) — the button
      // is the fallback, same as for a photo never scanned.
      return;
    }
    if (stored.isEmpty || !mounted) return;
    final crops = await FaceCrops.of(path, stored);
    if (crops.isEmpty || !mounted) return;
    setState(() {
      _faces = crops;
      _faceRects = stored.take(crops.length).toList();
      _faceGuesses = List.filled(crops.length, null);
    });
    await _loadGuesses();
  }

  Future<void> _suggestWithAi() async {
    final path = widget.resolvedPath;
    if (path == null) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _suggesting = true;
      _suggestNote = null;
    });
    try {
      final analysis = await _aiVision.analyze(
        localId: widget.record.localId,
        imageFile: File(path),
      );
      final merged = {...widget.record.tags, ...analysis.tags}.toList();
      if (merged.length != widget.record.tags.length) {
        await widget.assetRecordStore.setTags(widget.record.localId, merged);
        if (mounted) widget.onRecordChanged(widget.record.withTags(merged));
      }
      if (!mounted) return;
      setState(() {
        _suggesting = false;
        _suggestNote = analysis.tags.isEmpty ? l10n.detailSuggestNothing : null;
      });
    } on AiAnalysisException {
      if (!mounted) return;
      // Nearly always "no key configured" — which is a setup step, not a
      // failure, so it points at where to do it.
      setState(() {
        _suggesting = false;
        _suggestNote = l10n.detailSuggestNoKey;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _suggesting = false;
        _suggestNote = l10n.detailSuggestNothing;
      });
    }
  }

  /// A face with a name on it is a person; until then it's a question.
  ///
  /// The face that was tapped becomes their picture, not the photo it came
  /// out of — a group shot would otherwise give everyone in it the same
  /// avatar, and whoever stood centre-frame would become the face of all of
  /// them.
  Future<void> _nameFace(int index) async {
    final person = await _addPerson();
    if (person != null && index < _faceRects.length) {
      final latest = await widget.personStore.getById(person.id);
      // Only when they haven't got one already, same as linking any photo.
      if (latest != null && latest.avatarFace == null) {
        await widget.personStore.update(
          latest.copyWith(
            avatarLocalId: widget.record.localId,
            avatarFace: () => _faceRects[index],
          ),
        );
      }
      // This screen names faces through its own picker rather than the
      // shared `nameFace`, so the teaching has to happen here too — or the
      // one surface where you're actually looking at the photo would be
      // the one that never learns from it.
      await _faceIdentity.remember(
        record: widget.record,
        face: _faceRects[index],
        personId: person.id,
      );
    }
    if (!mounted) return;
    // Named, so it stops being an open question.
    setState(() {
      _faces = [..._faces]..removeAt(index);
      _faceRects = [..._faceRects]..removeAt(index);
      _faceGuesses = [..._faceGuesses]..removeAt(index);
    });
    await _loadPeople();
  }

  /// Which albums this photo is in — shown as chips, tapped off to leave.
  List<Album> _albums = const [];

  Future<void> _loadAlbums() async {
    final store = widget.albumStore;
    if (store == null) return;
    final albums = <Album>[];
    for (final album in await store.listAll()) {
      if ((await store.localIdsIn(album.id)).contains(widget.record.localId)) {
        albums.add(album);
      }
    }
    if (!mounted) return;
    setState(() => _albums = albums);
  }

  /// Same picker as the library's, for the same reason: adding one photo to
  /// an album is the same decision as adding forty, and a photo you're
  /// already looking at is the likeliest one to want filed.
  Future<void> _addToAlbum() async {
    final l10n = AppLocalizations.of(context)!;
    final store = widget.albumStore;
    if (store == null) return;
    final albums = await store.listAll();
    if (!mounted) return;
    final album = await showSearchPickerSheetOf<Album>(
      context: context,
      title: l10n.albumAddToAction,
      options: albums.where((a) => !_albums.any((m) => m.id == a.id)).toList(),
      labelOf: (a) => a.name,
      emptyHint: l10n.albumsNewNamePlaceholder,
      createLabel: (query) =>
          query.isEmpty ? null : l10n.personPickerNewNamed(query),
      onCreate: (query) => store.upsert(id: store.newId(), name: query),
    );
    if (album == null) return;
    await store.addAssets(album.id, [widget.record.localId]);
    await _loadAlbums();
  }

  Future<void> _removeFromAlbum(Album album) async {
    final store = widget.albumStore;
    if (store == null) return;
    await store.removeAsset(album.id, widget.record.localId);
    await _loadAlbums();
  }

  Future<void> _loadPeople() async {
    final people = await widget.personStore.peopleFor(widget.record.localId);
    if (!mounted) return;
    setState(() => _people = people);
  }

  Future<void> _editDateTime() async {
    final l10n = AppLocalizations.of(context)!;
    var picked = widget.record.createdAt.toLocal();
    final saved = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(l10n.detailEditDateTimeTitle),
        message: SizedBox(
          height: 200,
          child: CupertinoDatePicker(
            mode: CupertinoDatePickerMode.dateAndTime,
            initialDateTime: picked,
            maximumDate: DateTime.now(),
            onDateTimeChanged: (value) => picked = value,
          ),
        ),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.settingsSaveButton),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (saved != true) return;
    await setCreatedAtEverywhere(
      widget.assetRecordStore,
      widget.record,
      picked,
    );
    widget.onRecordChanged(widget.record.withCreatedAt(picked));
  }

  /// Same "search existing, or type to create" drop-down used for education/
  /// job titles and relationship organizations — fuzzy-matches locations
  /// already used on other photos, no separate "create" affordance needed.
  /// Opens where the photo was taken, on the map, from its own GPS tag —
  /// not from the place name, which is a label someone may have typed.
  ///
  /// A `geo:` URL would let the phone pick its own map app, which sounds
  /// better and isn't: iOS has no handler for it, so it silently fails.
  /// The https form opens Google Maps where it's installed and the
  /// browser where it isn't, which is a working answer either way.
  Future<void> _openOnMap() async {
    final record = widget.record;
    final latitude = record.latitude;
    final longitude = record.longitude;
    if (latitude == null || longitude == null) return;
    final url = Uri.parse(
      'https://www.google.com/maps/search/?api=1'
      '&query=$latitude,$longitude',
    );
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      // No browser, no map, no handler. Nothing was lost — the
      // coordinates are still on the row above.
    }
  }

  Future<void> _editLocation() async {
    final l10n = AppLocalizations.of(context)!;
    final options = await widget.assetRecordStore.allLocations();
    if (!mounted) return;
    final value = await showSearchPickerSheet(
      context: context,
      title: l10n.detailInfoLocation,
      options: options,
      selected: widget.record.location,
      clearLabel: widget.record.location == null
          ? null
          : l10n.detailInfoNoLocation,
    );
    if (value == null) return;
    final normalized = value.trim().isEmpty ? null : value.trim();
    await widget.assetRecordStore.setLocation(
      widget.record.localId,
      normalized,
    );
    widget.onRecordChanged(widget.record.withLocation(normalized));
  }

  /// The occasion this photo belongs to — what the Events collection
  /// groups by, picked the same way as Location.
  Future<void> _editEvent() async {
    final l10n = AppLocalizations.of(context)!;
    final options = await widget.assetRecordStore.allEvents();
    if (!mounted) return;
    final value = await showSearchPickerSheet(
      context: context,
      title: l10n.detailInfoEvent,
      options: options,
      selected: widget.record.event,
      clearLabel: widget.record.event == null ? null : l10n.detailInfoNoEvent,
    );
    if (value == null) return;
    final normalized = value.trim().isEmpty ? null : value.trim();
    await widget.assetRecordStore.setEvent(widget.record.localId, normalized);
    widget.onRecordChanged(widget.record.withEvent(normalized));
  }

  void _saveDescription(String value) {
    widget.assetRecordStore.setDescription(widget.record.localId, value);
    widget.onRecordChanged(widget.record.withDescription(value));
  }

  /// Fuzzy search-or-create, scoped to tags already used on other photos
  /// and not already on this one.
  Future<void> _addTag() async {
    final l10n = AppLocalizations.of(context)!;
    final allTags = await widget.assetRecordStore.allTags();
    final options = allTags.difference(widget.record.tags.toSet());
    if (!mounted) return;
    final tag = await showSearchPickerSheet(
      context: context,
      title: l10n.detailTagsHeader,
      options: options,
    );
    if (tag == null || tag.isEmpty || widget.record.tags.contains(tag)) return;
    final updated = [...widget.record.tags, tag];
    await widget.assetRecordStore.setTags(widget.record.localId, updated);
    widget.onRecordChanged(widget.record.withTags(updated));
  }

  Future<void> _removeTag(String tag) async {
    final updated = widget.record.tags.where((t) => t != tag).toList();
    await widget.assetRecordStore.setTags(widget.record.localId, updated);
    widget.onRecordChanged(widget.record.withTags(updated));
  }

  /// Returns whoever was picked or created, so a caller that knows *which*
  /// face this was can finish the job.
  Future<Person?> _addPerson() async {
    final l10n = AppLocalizations.of(context)!;
    final allPeople = await widget.personStore.listAll();
    final taggedIds = _people.map((p) => p.id).toSet();
    final candidates = allPeople
        .where((p) => !taggedIds.contains(p.id))
        .toList();
    if (!mounted) return null;
    final picked = await showPersonPickerSheet(
      context: context,
      candidates: candidates,
      personStore: widget.personStore,
      title: l10n.detailPeopleTagPickerTitle,
    );
    if (picked == null) return null;
    await widget.personStore.addAssets(picked.id, [widget.record.localId]);
    await _loadPeople();
    return picked;
  }

  Future<void> _removePerson(Person person) async {
    await widget.personStore.removeAsset(person.id, widget.record.localId);
    await _loadPeople();
  }

  Future<void> _openPerson(Person person) async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => PersonPageScreen(
          person: person,
          personStore: widget.personStore,
          assetRecordStore: widget.assetRecordStore,
        ),
      ),
    );
    await _loadPeople();
  }

  Future<void> _load() async {
    // Pixel size comes off the library entry at scan time; decoding a
    // full-size original just to print "5857 × 3905" is only the fallback
    // for a manually-added file the scan never saw.
    final stored = widget.record;
    if (stored.width != null && stored.height != null) {
      setState(() {
        _width = stored.width;
        _height = stored.height;
      });
    }
    final path = widget.resolvedPath;
    if (path == null) return;
    final file = File(path);
    int? bytes, width, height;
    try {
      bytes = (await file.stat()).size;
    } catch (_) {}
    if (!widget.record.isVideo && _width == null) {
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
      _width = width ?? _width;
      _height = height ?? _height;
    });
  }

  String _statusLabel(AppLocalizations l10n, UploadStatus status) =>
      switch (status) {
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
    final path = widget.resolvedPath;
    final format = path != null && p.extension(path).isNotEmpty
        ? p.extension(path).substring(1).toUpperCase()
        : null;
    final duration = widget.videoController?.value.duration;

    return Container(
      color: _screenBackground,
      // Room under the panel for the keyboard, so a focused field can be
      // scrolled clear of it rather than the whole page being shoved up.
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        40 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 5,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          GestureDetector(
            onTap: _editDateTime,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  DateFormat.yMMMMEEEEd().add_jm().format(
                    record.createdAt.toLocal(),
                  ),
                  style: const TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (path != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      p.basename(path),
                      style: const TextStyle(
                        color: CupertinoColors.systemGrey,
                        fontSize: 13,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // A cloud-only photo's one real action, and the first thing in
          // the panel because it is the answer to the note on the picture
          // above it. It used to float over the photo itself, which put a
          // blue pill across the bottom third of every cloud-only
          // photo — over the picture it was offering to improve.
          if (widget.cloudOnly)
            CupertinoListSection.insetGrouped(
              margin: const EdgeInsets.only(bottom: 16),
              backgroundColor: _screenBackground,
              decoration: const BoxDecoration(
                color: Color(0xFF2C2C2E),
                borderRadius: BorderRadius.all(Radius.circular(10)),
              ),
              children: [
                CupertinoListTile(
                  onTap: widget.restoring ? null : widget.onRestoreOriginal,
                  leading: const Icon(
                    CupertinoIcons.cloud_download,
                    color: CupertinoColors.activeBlue,
                  ),
                  title: Text(
                    widget.restoring
                        ? l10n.detailRestoringOriginal
                        : l10n.detailRestoreOriginal,
                    style: TextStyle(
                      color: widget.restoring
                          ? CupertinoColors.systemGrey
                          : CupertinoColors.activeBlue,
                    ),
                  ),
                  subtitle: Text(l10n.detailCloudOnlyNote),
                  trailing: widget.restoring
                      ? const CupertinoActivityIndicator()
                      : const CupertinoListTileChevron(),
                ),
              ],
            ),
          CupertinoListSection.insetGrouped(
            margin: EdgeInsets.zero,
            backgroundColor: _screenBackground,
            decoration: const BoxDecoration(
              color: Color(0xFF2C2C2E),
              borderRadius: BorderRadius.all(Radius.circular(10)),
            ),
            children: [
              CupertinoListTile(
                title: Text(l10n.detailInfoLocation),
                additionalInfo: Text(
                  record.location ?? l10n.detailInfoNoLocation,
                ),
                // Only where the photo actually carries coordinates. A
                // place *name* can be typed in by hand and means nothing
                // to a map; a pin that opens the wrong street is worse
                // than no pin.
                trailing: record.latitude == null || record.longitude == null
                    ? null
                    : CupertinoButton(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(44, 44),
                        onPressed: _openOnMap,
                        child: const Icon(
                          CupertinoIcons.map_pin_ellipse,
                          size: 20,
                          color: CupertinoColors.activeBlue,
                        ),
                      ),
                onTap: _editLocation,
              ),
              CupertinoListTile(
                title: Text(l10n.detailInfoEvent),
                additionalInfo: Text(record.event ?? l10n.detailInfoNoEvent),
                onTap: _editEvent,
              ),
              if (_width != null && _height != null)
                CupertinoListTile(
                  title: Text(l10n.detailInfoDimensions),
                  additionalInfo: Text('$_width × $_height'),
                ),
              if (duration != null)
                CupertinoListTile(
                  title: Text(l10n.detailInfoDuration),
                  additionalInfo: Text(_formatDuration(duration)),
                ),
              if (_bytes != null)
                CupertinoListTile(
                  title: Text(l10n.detailInfoFileSize),
                  additionalInfo: Text(_formatBytes(_bytes!)),
                ),
              if (format != null)
                CupertinoListTile(
                  title: Text(l10n.detailInfoFormat),
                  additionalInfo: Text(format),
                ),
              CupertinoListTile(
                title: Text(l10n.detailInfoStatus),
                additionalInfo: Text(
                  _statusLabel(
                    l10n,
                    record.stateOf(DerivativeKind.original).status,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_suggestion != null) ...[
            _SuggestionCard(
              suggestion: _suggestion!,
              onKeep: _keepSuggestion,
              onDismiss: _dropSuggestion,
            ),
            const SizedBox(height: 16),
          ],
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: Color(0xFF2C2C2E),
              borderRadius: BorderRadius.all(Radius.circular(10)),
            ),
            child: CupertinoTextField.borderless(
              controller: _description,
              maxLines: null,
              // A tap anywhere else on the page puts the keyboard away.
              // Without this the field keeps focus until something else
              // takes it, and on a page that is mostly photo there is
              // usually nothing else to take it.
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              placeholder: l10n.detailDescriptionPlaceholder,
              placeholderStyle: const TextStyle(
                color: CupertinoColors.systemGrey,
              ),
              style: const TextStyle(color: CupertinoColors.white),
              padding: EdgeInsets.zero,
              onChanged: _saveDescription,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              _SuggestButton(
                label: l10n.detailSuggestAi,
                icon: CupertinoIcons.sparkles,
                onPressed: _suggesting || widget.resolvedPath == null
                    ? null
                    : _suggestWithAi,
              ),
              if (_suggesting) ...[
                const SizedBox(width: 12),
                const CupertinoActivityIndicator(radius: 8),
              ],
            ],
          ),
          // Only when there's something to say — a standing explanation
          // under two self-describing buttons is just noise.
          if (_suggestNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _suggestNote!,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.35,
                  color: CupertinoColors.systemOrange,
                ),
              ),
            ),
          const SizedBox(height: 24),
          _SectionHeader(title: l10n.detailTagsHeader, onAdd: _addTag),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in record.tags)
                _Chip(label: tag, onRemove: () => _removeTag(tag)),
            ],
          ),
          const SizedBox(height: 24),
          _SectionHeader(title: l10n.detailPeopleHeader, onAdd: _addPerson),
          // Its own row under the heading, not floating in the middle of
          // it: a heading carries a title and, at most, the one control
          // that acts on the section as a whole. Two things in there and
          // neither reads as the title.
          Align(
            alignment: Alignment.centerLeft,
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 4),
              minimumSize: Size.zero,
              onPressed: _suggesting || widget.resolvedPath == null
                  ? null
                  : _suggestOnDevice,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    CupertinoIcons.viewfinder,
                    size: 15,
                    color: _suggesting || widget.resolvedPath == null
                        ? CupertinoColors.systemGrey
                        : CupertinoColors.activeBlue,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    l10n.detailFindFaces,
                    style: TextStyle(
                      fontSize: 13,
                      color: _suggesting || widget.resolvedPath == null
                          ? CupertinoColors.systemGrey
                          : CupertinoColors.activeBlue,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_faces.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Text(
                l10n.detailFacesHint,
                style: const TextStyle(
                  fontSize: 11,
                  color: CupertinoColors.systemGrey,
                ),
              ),
            ),
            SizedBox(
              // 60 for the crop, the rest for a name under it when there
              // is one — reserved either way, so a guess arriving doesn't
              // shunt the section below it.
              height: 80,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _faces.length,
                separatorBuilder: (context, i) => const SizedBox(width: 10),
                itemBuilder: (context, i) => GestureDetector(
                  onTap: () => _nameFace(i),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipOval(
                        child: Image.memory(
                          _faces[i],
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                        ),
                      ),
                      // Only where there's a guess. A row of "?" under
                      // every face is noise saying what the row already
                      // says.
                      if (_faceGuesses.length > i && _faceGuesses[i] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            l10n.peopleSuggestedFace(_faceGuesses[i]!),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: CupertinoColors.systemGrey,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [
              for (final person in _people)
                _PersonChip(
                  person: person,
                  assetRecordStore: widget.assetRecordStore,
                  onTap: () => _openPerson(person),
                  onRemove: () => _removePerson(person),
                ),
            ],
          ),
          // Only where the caller brought an album store: opened from a
          // person's page there's nothing to file into.
          if (widget.albumStore != null) ...[
            const SizedBox(height: 24),
            _SectionHeader(title: l10n.collectionsAlbums, onAdd: _addToAlbum),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final album in _albums)
                  _Chip(
                    label: album.name,
                    onRemove: () => _removeFromAlbum(album),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// What the analyze pass suggested for this photo, waiting to be kept or
/// thrown away. Nothing here is on the photo yet — that's the whole
/// difference between a suggestion and a tag.
class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.suggestion,
    required this.onKeep,
    required this.onDismiss,
  });

  final AiPhotoAnalysis suggestion;
  final Future<void> Function() onKeep;
  final Future<void> Function() onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF0A84FF), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                CupertinoIcons.sparkles,
                size: 15,
                color: Color(0xFF0A84FF),
              ),
              const SizedBox(width: 6),
              Text(
                l10n.analyzeReviewSuggestionTitle,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF0A84FF),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (suggestion.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                suggestion.description,
                style: const TextStyle(
                  fontSize: 14,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          if (suggestion.eventLabel.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.analyzeReviewSuggestedEvent(suggestion.eventLabel),
                style: const TextStyle(
                  fontSize: 12,
                  color: CupertinoColors.systemGrey,
                ),
              ),
            ),
          if (suggestion.tags.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in suggestion.tags)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3A3A3C),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      tag,
                      style: const TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.white,
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              CupertinoButton(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                minimumSize: const Size(0, 32),
                borderRadius: BorderRadius.circular(16),
                color: const Color(0xFF3A3A3C),
                onPressed: () => onKeep(),
                child: Text(
                  l10n.analyzeReviewAccept,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF0A84FF),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                onPressed: () => onDismiss(),
                child: Text(
                  l10n.analyzeReviewDismiss,
                  style: const TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.systemGrey,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.onAdd});

  final String title;

  /// Absent for a section with nothing to add by hand.
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: CupertinoColors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        if (onAdd != null)
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: onAdd,
            child: const Icon(
              CupertinoIcons.add_circled,
              color: CupertinoColors.systemGrey,
            ),
          ),
      ],
    );
  }
}

/// One of the two "fill this in for me" buttons. Deliberately a pair and
/// deliberately labelled: free-and-on-your-phone versus billed-to-your-key
/// is a choice the user should make per photo, not a setting they forget
/// they turned on.
class _SuggestButton extends StatelessWidget {
  const _SuggestButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => CupertinoButton(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    minimumSize: Size.zero,
    borderRadius: BorderRadius.circular(18),
    color: const Color(0xFF2C2C2E),
    onPressed: onPressed,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 15,
          color: onPressed == null
              ? CupertinoColors.systemGrey
              : CupertinoColors.white,
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: onPressed == null
                ? CupertinoColors.systemGrey
                : CupertinoColors.white,
          ),
        ),
      ],
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: CupertinoColors.darkBackgroundGray,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(color: CupertinoColors.white, fontSize: 13),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onRemove,
            child: const Icon(
              CupertinoIcons.xmark_circle_fill,
              size: 16,
              color: CupertinoColors.systemGrey,
            ),
          ),
        ],
      ),
    );
  }
}

class _PersonChip extends StatelessWidget {
  const _PersonChip({
    required this.person,
    required this.assetRecordStore,
    required this.onTap,
    required this.onRemove,
  });

  final Person person;
  final AssetRecordStore assetRecordStore;

  /// Opens this person's page — the little x (a separate, smaller tap
  /// target layered on top) still just untags them.
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              PersonAvatar(
                assetRecordStore: assetRecordStore,
                localId: person.avatarLocalId,
                face: person.avatarFace,
                size: 56,
              ),
              Positioned(
                right: -4,
                top: -4,
                child: GestureDetector(
                  onTap: onRemove,
                  child: const Icon(
                    CupertinoIcons.xmark_circle_fill,
                    size: 18,
                    color: CupertinoColors.systemGrey,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 64,
            child: Text(
              person.name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: CupertinoColors.white,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

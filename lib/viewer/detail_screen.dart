import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
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
import '../photos/ai_analysis_store.dart';
import '../photos/ai_vision_service.dart';
import '../photos/face_crops.dart';
import '../photos/on_device_analysis.dart';
import '../photos/on_device_vision.dart';
import '../photos/photo_library_service.dart';
import '../photos/photo_location.dart';
import '../settings/backup_targets_store.dart';
import '../storage/album.dart';
import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/original_restore.dart';
import 'person_avatar.dart';
import 'person_page_screen.dart';
import 'live_photo_view.dart';
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

enum _EditChoice { crop, rotate, aiTouchUp }

/// Runs off the UI isolate via [compute] — decode+encode of a full-size
/// photo is heavy enough to jank a frame otherwise.
Uint8List? _reencode((Uint8List bytes, _ExportFormat format) args) {
  final decoded = img.decodeImage(args.$1);
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

  /// One per visited page (keyed by `localId`), so the info-circle button
  /// can reveal the *current* page's info panel without needing a fresh
  /// controller lookup through the `PageView`.
  final _scrollControllers = <String, ScrollController>{};

  ScrollController _scrollControllerFor(AssetRecord record) =>
      _scrollControllers.putIfAbsent(record.localId, () => ScrollController());

  /// Whether the photo on screen is zoomed in — see the pager's `physics`.
  bool _zoomed = false;

  @override
  void dispose() {
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
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

  /// "Share Original" (as-is, any media type) or — stills only —
  /// "Export As…" to re-encode into a different image format first.
  Future<void> _showShareSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final record = _records[_index];
    final path = await _resolvePath(record);
    if (!mounted) return;
    if (path == null) {
      _showMessage(l10n.detailFileUnavailable);
      return;
    }
    final choice = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.detailShareOriginalOption),
          ),
          if (!record.isVideo)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.detailExportAsOption),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == false) {
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
      return;
    }
    await _exportAndShare(path);
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
    if (_records[_index].isVideo) {
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
    return CupertinoPageScaffold(
      backgroundColor: _screenBackground,
      // The keyboard must not relayout the page under it. Resizing shrinks
      // the full-height media sliver, which drags the photo and everything
      // under it upward the moment a caption field takes focus — the field
      // scrolls into view on its own (see the info panel's keyboard
      // padding), so nothing here needs to move.
      resizeToAvoidBottomInset: false,
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
                            padding: const EdgeInsets.symmetric(horizontal: 16),
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
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _records.length,
                // A zoomed photo owns every drag on it. Panning around
                // one and swiping to the next are the same gesture, and
                // the pager wins that fight by default — which made a
                // zoomed photo impossible to look around.
                physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => _MediaPage(
                  record: _records[i],
                  albumStore: widget.albumStore,
                  resolveFile: widget.resolvePhotoManagerFile,
                  resolveLiveVideo: widget.resolveLivePhotoVideo,
                  resolvePlaceName: widget.resolvePlaceName,
                  restoreOriginal: widget.restoreOriginal,
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
            Padding(
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
          ],
        ),
      ),
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
    required this.onZoomChanged,
    this.onDeviceAnalysis,
    this.aiVisionService,
    this.resolveFile,
    this.resolveLiveVideo,
    this.resolvePlaceName,
    this.restoreOriginal,
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

  /// Owned by `_DetailScreenState` — the info-circle button in the bottom
  /// bar drives it directly, so this page's `CustomScrollView` just needs
  /// to use it.
  final ScrollController scrollController;

  /// Tells the pager this page is zoomed, so it stops taking the drags that
  /// are meant to move the photo around.
  final ValueChanged<bool> onZoomChanged;

  /// See [DetailScreen.onDeviceAnalysis].
  final OnDeviceAnalysisService? onDeviceAnalysis;
  final AiVisionService? aiVisionService;

  @override
  State<_MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<_MediaPage> {
  VideoPlayerController? _videoController;
  Object? _error;

  /// `photoManager` records carry no `sourcePath` — it's resolved on demand
  /// here via `photo_manager`, same as the library grid does. `null` while
  /// still resolving; stays `null` for good if the asset's gone from the
  /// library or was never resolvable.
  String? _path;
  bool _resolvingPath = false;

  bool _dismissed = false;

  /// Pull the photo down and it goes back to the grid, same as real Photos
  /// — and a pull that comes out at an angle is still a pull.
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
  /// and the pull is read from the pointer, outside the arena, where the
  /// only question that matters can be asked directly: did this go down
  /// far enough, and more down than sideways?
  static const _dismissPullDistance = 64.0;

  /// How much of the drag is allowed to be sideways. A thumb pulling down
  /// swings through an arc, so demanding it go down further than it goes
  /// across ruled out most real pulls; at 0.7 anything steeper than about
  /// 35 degrees off horizontal counts, which still leaves a swipe to the
  /// next photo unmistakable.
  static const _dismissPullLean = 0.7;

  int _pointers = 0;
  Offset? _pullOrigin;

  /// Only from the top of the page: further down, a drag downward is the
  /// info panel being put back, not the photo being let go of.
  bool get _atTop {
    final controller = widget.scrollController;
    return !controller.hasClients || controller.position.pixels <= 0;
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers++;
    // A second finger means a pinch — nobody dismisses a photo with two.
    _pullOrigin = _pointers > 1 || _zoomed || !_atTop ? null : event.position;
  }

  void _onPointerMove(PointerMoveEvent event) {
    final origin = _pullOrigin;
    if (origin == null || _dismissed) return;
    final moved = event.position - origin;
    if (moved.dy < _dismissPullDistance ||
        moved.dy <= moved.dx.abs() * _dismissPullLean) {
      return;
    }
    if (!_atTop) {
      _pullOrigin = null;
      return;
    }
    _dismissed = true;
    Navigator.of(context).pop();
  }

  void _onPointerDone(PointerEvent event) {
    if (_pointers > 0) _pointers--;
    _pullOrigin = null;
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

  @override
  void initState() {
    super.initState();
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
    super.dispose();
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
  Widget _cloudOnly(AppLocalizations l10n) {
    final thumbnail = widget.record.thumbnailPath;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumbnail != null)
          Center(
            child: Image.file(
              File(thumbnail),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) =>
                  _MissingFileNote(message: l10n.detailFileUnavailable),
            ),
          )
        else
          _MissingFileNote(message: l10n.detailFileUnavailable),
        Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: Center(
            child: CupertinoButton.filled(
              onPressed: _restoring ? null : _restoreOriginal,
              child: Text(
                _restoring
                    ? l10n.detailRestoringOriginal
                    : l10n.detailRestoreOriginal,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _media(AppLocalizations l10n) {
    if (_localDeleted) return _cloudOnly(l10n);
    final path = _path;
    if (path == null) {
      if (_resolvingPath) {
        return const Center(
          child: CupertinoActivityIndicator(color: CupertinoColors.white),
        );
      }
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
    final still = _ZoomableImage(
      file: File(path),
      onZoomChanged: _onZoomChanged,
      errorBuilder: (context, error, stackTrace) =>
          _MissingFileNote(message: l10n.detailFileUnavailable),
    );
    if (!widget.record.isLivePhoto) return still;
    return LivePhotoView(
      still: still,
      resolveVideo: () =>
          (widget.resolveLiveVideo ??
          PhotoLibraryService.resolveLivePhotoVideo)(widget.record),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerDone,
      onPointerCancel: _onPointerDone,
      child: LayoutBuilder(
        builder: (context, constraints) => CustomScrollView(
          controller: widget.scrollController,
          physics: _zoomed
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
  });

  final File file;
  final ImageErrorWidgetBuilder errorBuilder;

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
        child: Center(
          child: Image.file(
            widget.file,
            fit: BoxFit.contain,
            errorBuilder: widget.errorBuilder,
          ),
        ),
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
    _loadPeople();
    _loadAlbums();
    _fillLocationFromMetadata();
  }

  @override
  void didUpdateWidget(_InfoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // `resolvedPath` starts null for `photoManager` records and arrives
    // once `_MediaPage` finishes resolving it — reload when that happens.
    if (oldWidget.resolvedPath != widget.resolvedPath) _load();
    if (oldWidget.record.localId != widget.record.localId) {
      _description.text = widget.record.description;
      _loadPeople();
      _loadAlbums();
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

  /// Face thumbnails from the last Auto Suggest, waiting to be named. Not
  /// persisted: a face nobody has put a name to isn't worth storing, and
  /// re-finding them costs one Vision call.
  List<Uint8List> _faces = const [];

  /// Where each of [_faces] sits in the photo, same order — what makes the
  /// tapped face become *that* person's picture rather than the whole
  /// group shot.
  List<VisionFace> _faceRects = const [];
  bool _suggesting = false;
  String? _suggestNote;

  late final OnDeviceAnalysisService _onDeviceAnalysis =
      widget.onDeviceAnalysis ??
      OnDeviceAnalysisService(analysisStore: AiAnalysisStore());
  late final AiVisionService _aiVision =
      widget.aiVisionService ?? AiVisionService();

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
    final faces = await _onDeviceAnalysis.analyze(widget.record, path);
    final crops = await FaceCrops.of(path, faces);
    if (!mounted) return;
    setState(() {
      _suggesting = false;
      _faces = crops;
      _faceRects = faces.take(crops.length).toList();
      _suggestNote = crops.isEmpty ? l10n.detailSuggestNothing : null;
    });
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
            avatarFace: () => _faceRects[index].toPersonFace(),
          ),
        );
      }
    }
    if (!mounted) return;
    // Named, so it stops being an open question.
    setState(() {
      _faces = [..._faces]..removeAt(index);
      _faceRects = [..._faceRects]..removeAt(index);
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
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _faces.length,
                separatorBuilder: (context, i) => const SizedBox(width: 10),
                itemBuilder: (context, i) => GestureDetector(
                  onTap: () => _nameFace(i),
                  child: ClipOval(
                    child: Image.memory(
                      _faces[i],
                      width: 60,
                      height: 60,
                      fit: BoxFit.cover,
                    ),
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

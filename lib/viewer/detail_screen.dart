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
import '../photos/ai_touch_up_queue.dart';
import '../photos/derived_asset.dart';
import '../photos/person.dart';
import '../photos/person_store.dart';
import '../photos/photo_library_service.dart';
import '../photos/photo_location.dart';
import '../settings/backup_targets_store.dart';
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
    this.resolvePhotoManagerFile,
    this.resolveLivePhotoVideo,
    this.resolvePlaceName,
    this.restoreOriginal,
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
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) => _MediaPage(
                  record: _records[i],
                  resolveFile: widget.resolvePhotoManagerFile,
                  resolveLiveVideo: widget.resolveLivePhotoVideo,
                  resolvePlaceName: widget.resolvePlaceName,
                  restoreOriginal: widget.restoreOriginal,
                  assetRecordStore: widget.assetRecordStore,
                  personStore: _personStore,
                  onRecordChanged: _updateRecord,
                  scrollController: _scrollControllerFor(_records[i]),
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
  final ValueChanged<AssetRecord> onRecordChanged;

  /// Re-downloads a cloud-only asset's original ([AssetRecord.localDeleted])
  /// and returns its new local path. Defaults to a real [OriginalRestore];
  /// overridable for tests so they never make a network call.
  final Future<String?> Function(AssetRecord record)? restoreOriginal;

  /// Owned by `_DetailScreenState` — the info-circle button in the bottom
  /// bar drives it directly, so this page's `CustomScrollView` just needs
  /// to use it.
  final ScrollController scrollController;

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
    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: LayoutBuilder(
        builder: (context, constraints) => CustomScrollView(
          controller: widget.scrollController,
          physics: const BouncingScrollPhysics(),
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
                resolvePlaceName: widget.resolvePlaceName,
                resolvedPath: _path,
                videoController: _videoController,
                assetRecordStore: widget.assetRecordStore,
                personStore: widget.personStore,
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
  const _ZoomableImage({required this.file, required this.errorBuilder});

  final File file;
  final ImageErrorWidgetBuilder errorBuilder;

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

  bool get _isZoomed => _transformation.value.getMaxScaleOnAxis() > 1.01;

  @override
  void initState() {
    super.initState();
    _animController.addListener(() {
      final animation = _animation;
      if (animation != null) _transformation.value = animation.value;
    });
  }

  @override
  void dispose() {
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
        onInteractionEnd: (_) => setState(() {}),
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
    required this.resolvePlaceName,
    required this.resolvedPath,
    required this.videoController,
    required this.assetRecordStore,
    required this.personStore,
    required this.onRecordChanged,
  });

  final AssetRecord record;

  /// Same value `_MediaPage` resolved and rendered — `photoManager` records
  /// have no `record.sourcePath` of their own.
  final String? resolvedPath;

  /// See [DetailScreen.resolvePlaceName].
  final Future<String?> Function(AssetRecord record)? resolvePlaceName;

  final VideoPlayerController? videoController;
  final AssetRecordStore assetRecordStore;
  final PersonStore personStore;
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
        widget.resolvePlaceName ?? PhotoLocationService().placeNameFor;
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
    await widget.assetRecordStore.setCreatedAt(widget.record.localId, picked);
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

  Future<void> _addPerson() async {
    final l10n = AppLocalizations.of(context)!;
    final allPeople = await widget.personStore.listAll();
    final taggedIds = _people.map((p) => p.id).toSet();
    final candidates = allPeople
        .where((p) => !taggedIds.contains(p.id))
        .toList();
    if (!mounted) return;
    final picked = await showPersonPickerSheet(
      context: context,
      candidates: candidates,
      personStore: widget.personStore,
      title: l10n.detailPeopleTagPickerTitle,
    );
    if (picked == null) return;
    await widget.personStore.addAssets(picked.id, [widget.record.localId]);
    await _loadPeople();
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
    final path = widget.resolvedPath;
    if (path == null) return;
    final file = File(path);
    int? bytes, width, height;
    try {
      bytes = (await file.stat()).size;
    } catch (_) {}
    if (!widget.record.isVideo) {
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
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
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
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.onAdd});

  final String title;
  final VoidCallback onAdd;

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

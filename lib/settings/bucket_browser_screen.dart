import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../storage/asset_record_store.dart';
import '../upload/bucket_ops.dart';
import 'bucket_object_preview_screen.dart';
import 's3_backup_target.dart';
import 's3_listing.dart';
import 'settings_section.dart';

/// Browses one [target]'s bucket, one folder level at a time — recursing by
/// pushing itself with the tapped sub-prefix. Same screen at every depth,
/// same actions, so there's no "detail" tier to learn.
///
/// The listing is live: each level asks S3 for that one folder
/// (`delimiter=/`), so what's on screen is what's in the bucket right now
/// rather than what this app last uploaded. That's the entire point —
/// "did my backup actually land, and how is it laid out" answered without
/// the AWS console.
///
/// Selecting files and deleting them lives here too, because this is the
/// only view of the bucket the app has. It's the one place where deleting
/// takes something away that may exist nowhere else, so it says so.
class BucketBrowserScreen extends StatefulWidget {
  BucketBrowserScreen({
    super.key,
    required this.target,
    String? prefix,
    this.highlightKey,
    this.listBucketFn = listBucket,
    this.ops,
    this.recordStore,
    this.onDeleteConnection,
  }) : prefix = prefix ?? target.prefix;

  final S3BackupTarget target;
  final String prefix;

  /// An object to scroll to and flash once listed — "Show in Bucket".
  final String? highlightKey;

  /// Overridable for tests so they never make a real network call.
  final Future<S3ListingResult> Function({
    required S3BackupTarget target,
    String prefix,
    String? continuationToken,
  })
  listBucketFn;

  /// Deletes go through [BucketOps.deleteGuarded] and nothing else.
  /// Overridable for tests so they never really delete anything.
  final BucketOps? ops;

  /// What the guard asks whether a photo still uses a key.
  final AssetRecordStore? recordStore;

  /// Offered at the bucket's own root only — this screen *is* the
  /// connection, so it's where removing it belongs now that the row it used
  /// to hang off has no menu.
  final Future<void> Function()? onDeleteConnection;

  @override
  State<BucketBrowserScreen> createState() => _BucketBrowserScreenState();
}

class _BucketBrowserScreenState extends State<BucketBrowserScreen> {
  bool _loading = true;
  bool _loadingMore = false;
  String? _loadMoreError;
  bool _deleting = false;
  String? _error;
  List<String> _folders = const [];
  List<S3Object> _objects = const [];
  String? _nextToken;

  /// Non-null while selecting — the object keys ticked so far.
  Set<String>? _selection;

  bool get _isRoot => widget.prefix == widget.target.prefix;

  final _scroll = ScrollController();
  final _firstObjectRow = GlobalKey();
  final _highlightRow = GlobalKey();
  bool _flashing = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Pages on until [BucketBrowserScreen.highlightKey] is listed — bounded,
  /// since a folder can hold a hundred thousand objects — then scrolls to it.
  /// The list is lazy, so the jump is estimated from one row's height and
  /// then made exact once the row is built.
  Future<void> _reveal() async {
    final key = widget.highlightKey;
    if (key == null) return;
    for (var page = 0; page < 20; page++) {
      if (_objects.any((o) => o.key == key) || _nextToken == null) break;
      await _loadMore();
      if (!mounted || _error != null) return;
    }
    final index = _objects.indexWhere((o) => o.key == key);
    if (index == -1) return;
    setState(() => _flashing = true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_scroll.hasClients) return;
    final rowHeight = _firstObjectRow.currentContext?.size?.height;
    if (rowHeight != null && _highlightRow.currentContext == null) {
      final view = _scroll.position.viewportDimension;
      _scroll.jumpTo(
        ((_folders.length + index) * rowHeight - view * 0.3).clamp(
          0,
          _scroll.position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
    }
    final row = _highlightRow.currentContext;
    if (row != null && row.mounted) {
      await Scrollable.ensureVisible(
        row,
        alignment: 0.3,
        duration: const Duration(milliseconds: 250),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (mounted) setState(() => _flashing = false);
  }

  @override
  void initState() {
    super.initState();
    _load().then((_) => _reveal());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await widget.listBucketFn(
      target: widget.target,
      prefix: widget.prefix,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.isOk) {
        _folders = result.page!.folders;
        _objects = result.page!.objects
            .where((o) => o.key != widget.prefix)
            .toList();
        _nextToken = result.page!.nextToken;
      } else {
        _error = _messageFor(result);
      }
    });
  }

  Future<void> _loadMore() async {
    final token = _nextToken;
    if (token == null || _loadingMore) return;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    final result = await widget.listBucketFn(
      target: widget.target,
      prefix: widget.prefix,
      continuationToken: token,
    );
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      if (!result.isOk) {
        _loadMoreError = _messageFor(result);
        return;
      }
      _folders = [..._folders, ...result.page!.folders];
      _objects = [
        ..._objects,
        ...result.page!.objects.where((o) => o.key != widget.prefix),
      ];
      _nextToken = result.page!.nextToken;
    });
  }

  String _messageFor(S3ListingResult result) {
    final l10n = AppLocalizations.of(context)!;
    final base = switch (result.outcome) {
      S3ListingOutcome.forbidden => l10n.settingsAccessCheckForbidden,
      S3ListingOutcome.notFound => l10n.settingsAccessCheckNotFound,
      S3ListingOutcome.networkError => l10n.settingsAccessCheckNetworkError,
      S3ListingOutcome.ok => '',
    };
    final detail = result.detail;
    return detail == null ? base : '$base ($detail)';
  }

  String get _title {
    if (widget.prefix.isEmpty) return widget.target.bucket;
    final trimmed = widget.prefix.endsWith('/')
        ? widget.prefix.substring(0, widget.prefix.length - 1)
        : widget.prefix;
    return trimmed.contains('/')
        ? trimmed.substring(trimmed.lastIndexOf('/') + 1)
        : trimmed;
  }

  String _relativeName(String key) =>
      key.startsWith(widget.prefix) ? key.substring(widget.prefix.length) : key;

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var i = 0;
    while (value >= 1024 && i < units.length - 1) {
      value /= 1024;
      i++;
    }
    return '${value.toStringAsFixed(1)} ${units[i]}';
  }

  /// A bucket holds whatever the user keeps there, so the glyph is a guess
  /// off the extension rather than a claim — but a wall of identical
  /// document icons tells you nothing about a folder of photos.
  static final _photoName = RegExp(r'\.(jpe?g|png|heic|heif|webp|gif|tiff?)$');
  static final _videoName = RegExp(r'\.(mp4|mov|m4v|avi|mkv)$');

  static IconData iconFor(String key) {
    final name = key.toLowerCase();
    if (_photoName.hasMatch(name)) {
      return CupertinoIcons.photo_fill;
    }
    if (_videoName.hasMatch(name)) {
      return CupertinoIcons.videocam_fill;
    }
    return CupertinoIcons.doc_fill;
  }

  void _openFolder(String folderPrefix) {
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => BucketBrowserScreen(
          target: widget.target,
          prefix: folderPrefix,
          listBucketFn: widget.listBucketFn,
          ops: widget.ops,
          recordStore: widget.recordStore,
        ),
      ),
    );
  }

  void _toggleSelecting() =>
      setState(() => _selection = _selection == null ? <String>{} : null);

  void _toggleSelected(String key) => setState(() {
    final selection = _selection!;
    selection.contains(key) ? selection.remove(key) : selection.add(key);
  });

  late final BucketOps _ops = widget.ops ?? BucketOps();
  late final AssetRecordStore _store = widget.recordStore ?? AssetRecordStore();

  Future<DeleteOutcome> _guarded(String key, {bool dryRun = false}) =>
      _ops.deleteGuarded(widget.target, key, store: _store, dryRun: dryRun);

  /// Checked before asking: a key a photo uses, a carrier, or one the
  /// bucket won't answer for is refused, and said so. The rest are named
  /// in the confirm, and checked again as each goes.
  Future<void> _deleteSelected() async {
    final l10n = AppLocalizations.of(context)!;
    final keys = _selection?.toList() ?? const <String>[];
    if (keys.isEmpty) return;

    setState(() => _deleting = true);
    final allowed = <String>[];
    var refused = 0;
    for (final key in keys) {
      switch (await _guarded(key, dryRun: true)) {
        case DeleteOutcome.allowed:
          allowed.add(key);
        case DeleteOutcome.gone || DeleteOutcome.deleted:
          break;
        case _:
          refused++;
      }
    }
    if (!mounted) return;
    setState(() => _deleting = false);
    if (refused > 0) {
      await _tell(l10n.bucketBrowserDeleteRefused(refused));
      if (!mounted) return;
    }
    if (allowed.isEmpty) {
      setState(() => _selection = null);
      await _load();
      return;
    }

    const shown = 5;
    final names = [
      for (final key in allowed.take(shown)) key.split('/').last,
      if (allowed.length > shown) '…',
    ].join('\n');
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.bucketBrowserDeleteSelected(allowed.length)),
        content: Text(l10n.bucketBrowserDeleteNamed(names)),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    var failed = 0;
    for (final key in allowed) {
      if (!(await _guarded(key)).isGone) failed++;
    }
    if (!mounted) return;
    setState(() {
      _deleting = false;
      _selection = null;
    });
    if (failed > 0) await _tell(l10n.bucketBrowserDeleteFailed(failed));
    // Re-listed rather than patched locally: the bucket is the truth here,
    // and a delete that didn't take has to show as still present.
    await _load();
  }

  Future<void> _tell(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (dialogContext) => CupertinoAlertDialog(
      content: Text(message),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(AppLocalizations.of(context)!.actionOk),
        ),
      ],
    ),
  );

  Future<void> _confirmDeleteConnection() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.settingsDeleteConfirmTitle),
        content: Text(l10n.settingsDeleteConfirmBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.onDeleteConnection!();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final selection = _selection;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        middle: Text(_title),
        trailing: _loading || _error != null
            ? null
            : CupertinoButton(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                onPressed: _objects.isEmpty || _deleting
                    ? null
                    : _toggleSelecting,
                child: Text(
                  selection == null
                      ? l10n.bucketBrowserSelect
                      : l10n.selectionDone,
                  style: TextStyle(
                    fontSize: 15,
                    color: _objects.isEmpty || _deleting
                        ? settingsTertiary
                        : settingsAccent,
                  ),
                ),
              ),
      ),
      child: SafeArea(child: _body(l10n, selection)),
    );
  }

  Widget _body(AppLocalizations l10n, Set<String>? selection) {
    if (_loading) {
      return const Center(child: CupertinoActivityIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.bucketBrowserUnreachable,
                style: settingsRowTitleStyle,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: settingsHintStyle,
              ),
              const SizedBox(height: 12),
              CupertinoButton(
                key: const ValueKey('bucketBrowserRetry'),
                onPressed: _load,
                child: Text(l10n.actionRetry),
              ),
              if (_isRoot && widget.onDeleteConnection != null)
                CupertinoButton(
                  onPressed: _confirmDeleteConnection,
                  child: Text(
                    l10n.settingsDeleteConnectionAction,
                    style: const TextStyle(color: CupertinoColors.systemRed),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        ListView(
          controller: _scroll,
          padding: const EdgeInsets.only(top: 8, bottom: 96),
          children: [
            if (_folders.isEmpty && _objects.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.bucketBrowserEmpty,
                  textAlign: TextAlign.center,
                  style: settingsHintStyle,
                ),
              ),
            for (final folder in _folders) ...[
              SettingsRow(
                leading: const Icon(
                  CupertinoIcons.folder_fill,
                  color: settingsAccent,
                  size: 22,
                ),
                title: _relativeName(folder),
                trailing: const Icon(
                  CupertinoIcons.chevron_forward,
                  size: 14,
                  color: settingsSecondary,
                ),
                onTap: selection == null ? () => _openFolder(folder) : null,
              ),
              const SettingsHairline(indent: settingsPagePadding),
            ],
            for (final (i, object) in _objects.indexed) ...[
              AnimatedContainer(
                key: object.key == widget.highlightKey
                    ? _highlightRow
                    : i == 0
                    ? _firstObjectRow
                    : null,
                duration: const Duration(milliseconds: 600),
                color: _flashing && object.key == widget.highlightKey
                    ? settingsAccent.withValues(alpha: 0.22)
                    : const Color(0x00000000),
                child: SettingsRow(
                  leading: selection == null
                      ? Icon(
                          iconFor(object.key),
                          color: settingsSecondary,
                          size: 22,
                        )
                      : Icon(
                          selection.contains(object.key)
                              ? CupertinoIcons.checkmark_circle_fill
                              : CupertinoIcons.circle,
                          color: selection.contains(object.key)
                              ? settingsAccent
                              : settingsSecondary,
                          size: 22,
                        ),
                  title: _relativeName(object.key),
                  subtitle: formatBytes(object.size),
                  onTap: selection == null
                      ? () => Navigator.of(context).push(
                          CupertinoPageRoute(
                            builder: (_) => BucketObjectPreviewScreen(
                              target: widget.target,
                              objectKey: object.key,
                            ),
                          ),
                        )
                      : () => _toggleSelected(object.key),
                ),
              ),
              const SettingsHairline(indent: settingsPagePadding),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(
                settingsPagePadding,
                10,
                settingsPagePadding,
                0,
              ),
              // A status readout, not another tier of navigation — one line
              // under the list, the same shape as everywhere else.
              child: SettingsFooterLine(
                text: l10n.bucketBrowserStats(
                  _folders.length,
                  _objects.length,
                  _objects.isEmpty
                      ? ''
                      : ' · ${formatBytes(_objects.fold(0, (sum, o) => sum + o.size))}',
                ),
              ),
            ),
            if (_nextToken != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: _loadingMore
                      ? const CupertinoActivityIndicator()
                      : Column(
                          children: [
                            if (_loadMoreError case final error?)
                              Text(
                                error,
                                textAlign: TextAlign.center,
                                style: settingsHintStyle,
                              ),
                            CupertinoButton(
                              onPressed: _loadMore,
                              child: Text(l10n.bucketBrowserLoadMore),
                            ),
                          ],
                        ),
                ),
              ),
            if (_isRoot &&
                widget.onDeleteConnection != null &&
                selection == null) ...[
              const SettingsSectionDivider(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _confirmDeleteConnection,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: settingsPagePadding,
                    vertical: 10,
                  ),
                  child: Text(
                    l10n.settingsDeleteConnectionAction,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.systemRed,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        if (selection != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _DeleteBar(
              count: selection.length,
              busy: _deleting,
              onDelete: _deleteSelected,
            ),
          ),
      ],
    );
  }
}

class _DeleteBar extends StatelessWidget {
  const _DeleteBar({
    required this.count,
    required this.busy,
    required this.onDelete,
  });

  final int count;
  final bool busy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF2C2C2E),
        border: Border(top: BorderSide(color: settingsSeparator, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: settingsPagePadding,
            vertical: 8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.selectionTitle(count),
                  style: settingsRowTitleStyle,
                ),
              ),
              if (busy)
                const CupertinoActivityIndicator()
              else
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  onPressed: count == 0 ? null : onDelete,
                  child: Text(
                    l10n.actionDelete,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: count == 0
                          ? settingsTertiary
                          : CupertinoColors.systemRed,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

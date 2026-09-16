import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show MaterialPageRoute;

import '../l10n/app_localizations.dart';
import '../upload/s3_object_delete.dart' as s3;
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
    this.listBucketFn = listBucket,
    this.deleteObjectFn = s3.deleteObject,
    this.onDeleteConnection,
  }) : prefix = prefix ?? target.prefix;

  final S3BackupTarget target;
  final String prefix;

  /// Overridable for tests so they never make a real network call.
  final Future<S3ListingResult> Function({
    required S3BackupTarget target,
    String prefix,
    String? continuationToken,
  })
  listBucketFn;

  /// Overridable for tests so they never really delete anything.
  final Future<bool> Function({
    required S3BackupTarget target,
    required String key,
  })
  deleteObjectFn;

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
  bool _deleting = false;
  String? _error;
  List<String> _folders = const [];
  List<S3Object> _objects = const [];
  String? _nextToken;

  /// Non-null while selecting — the object keys ticked so far.
  Set<String>? _selection;

  bool get _isRoot => widget.prefix == widget.target.prefix;

  @override
  void initState() {
    super.initState();
    _load();
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
    setState(() => _loadingMore = true);
    final result = await widget.listBucketFn(
      target: widget.target,
      prefix: widget.prefix,
      continuationToken: token,
    );
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      if (!result.isOk) {
        _error = _messageFor(result);
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
  static IconData iconFor(String key) {
    final name = key.toLowerCase();
    if (RegExp(r'\.(jpe?g|png|heic|heif|webp|gif|tiff?)$').hasMatch(name)) {
      return CupertinoIcons.photo_fill;
    }
    if (RegExp(r'\.(mp4|mov|m4v|avi|mkv)$').hasMatch(name)) {
      return CupertinoIcons.videocam_fill;
    }
    return CupertinoIcons.doc_fill;
  }

  void _openFolder(String folderPrefix) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BucketBrowserScreen(
          target: widget.target,
          prefix: folderPrefix,
          listBucketFn: widget.listBucketFn,
          deleteObjectFn: widget.deleteObjectFn,
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

  Future<void> _deleteSelected() async {
    final l10n = AppLocalizations.of(context)!;
    final keys = _selection?.toList() ?? const <String>[];
    if (keys.isEmpty) return;

    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.bucketBrowserDeleteSelected(keys.length)),
        content: Text(l10n.bucketBrowserDeleteBody),
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
    if (confirmed != true) return;

    setState(() => _deleting = true);
    var failed = 0;
    for (final key in keys) {
      if (!await widget.deleteObjectFn(target: widget.target, key: key)) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      _deleting = false;
      _selection = null;
    });
    if (failed > 0) {
      await showCupertinoDialog<void>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          content: Text(l10n.bucketBrowserDeleteFailed(failed)),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.actionOk),
            ),
          ],
        ),
      );
    }
    // Re-listed rather than patched locally: the bucket is the truth here,
    // and a delete that didn't take has to show as still present.
    await _load();
  }

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
                onPressed: _objects.isEmpty ? null : _toggleSelecting,
                child: Text(
                  selection == null
                      ? l10n.bucketBrowserSelect
                      : l10n.selectionDone,
                  style: TextStyle(
                    fontSize: 15,
                    color: _objects.isEmpty ? settingsTertiary : settingsAccent,
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
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        ListView(
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
            for (final object in _objects) ...[
              SettingsRow(
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
                        MaterialPageRoute(
                          builder: (_) => BucketObjectPreviewScreen(
                            target: widget.target,
                            objectKey: object.key,
                          ),
                        ),
                      )
                    : () => _toggleSelected(object.key),
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
                      : CupertinoButton(
                          onPressed: _loadMore,
                          child: Text(l10n.bucketBrowserLoadMore),
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

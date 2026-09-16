import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'bucket_object_preview_screen.dart';
import 's3_backup_target.dart';
import 's3_listing.dart';

/// Browses one S3 [target]'s bucket contents — folders (grouped by S3 key
/// prefix, via `listBucket`'s `delimiter=/`) and objects with their size —
/// so "did my backup actually land, and how is it organized" has an answer
/// inside the app instead of requiring the AWS console/CLI. Material, like
/// the rest of `settings/` (see `app.dart`'s theme-bridging comment).
class BucketBrowserScreen extends StatefulWidget {
  BucketBrowserScreen({
    super.key,
    required this.target,
    String? prefix,
    this.listBucketFn = listBucket,
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

  @override
  State<BucketBrowserScreen> createState() => _BucketBrowserScreenState();
}

class _BucketBrowserScreenState extends State<BucketBrowserScreen> {
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  List<String> _folders = const [];
  List<S3Object> _objects = const [];
  String? _nextToken;

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
    if (token == null) return;
    setState(() => _loadingMore = true);
    final result = await widget.listBucketFn(
      target: widget.target,
      prefix: widget.prefix,
      continuationToken: token,
    );
    if (!mounted) return;
    setState(() {
      _loadingMore = false;
      if (result.isOk) {
        _objects = [
          ..._objects,
          ...result.page!.objects.where((o) => o.key != widget.prefix),
        ];
        _nextToken = result.page!.nextToken;
      } else {
        _error = _messageFor(result);
      }
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

  static String _formatBytes(int bytes) {
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

  void _openFolder(String folderPrefix) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BucketBrowserScreen(
          target: widget.target,
          prefix: folderPrefix,
          listBucketFn: widget.listBucketFn,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            )
          : (_folders.isEmpty && _objects.isEmpty)
          ? Center(
              child: Text(
                l10n.bucketBrowserEmpty,
                style: const TextStyle(color: Colors.grey),
              ),
            )
          : ListView(
              children: [
                for (final folder in _folders)
                  ListTile(
                    leading: const Icon(
                      Icons.folder_outlined,
                      color: Colors.amber,
                    ),
                    title: Text(_relativeName(folder)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openFolder(folder),
                  ),
                for (final object in _objects)
                  ListTile(
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(_relativeName(object.key)),
                    subtitle: Text(_formatBytes(object.size)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => BucketObjectPreviewScreen(
                          target: widget.target,
                          objectKey: object.key,
                        ),
                      ),
                    ),
                  ),
                if (_nextToken != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: _loadingMore
                          ? const CircularProgressIndicator()
                          : OutlinedButton(
                              onPressed: _loadMore,
                              child: Text(l10n.bucketBrowserLoadMore),
                            ),
                    ),
                  ),
              ],
            ),
    );
  }
}

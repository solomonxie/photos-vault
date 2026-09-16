import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../upload/signing.dart' as signing;
import 's3_backup_target.dart';

const _imageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.heic',
  '.heif',
  '.gif',
  '.bmp',
};

/// Previews one object from the Bucket Browser — a presigned `GET` so
/// nothing needs to be made public just to look at it. Still images render
/// inline (pinch-to-zoom); anything else (video, arbitrary files) offers
/// "Open Externally" instead of a bundled player/viewer for every format.
class BucketObjectPreviewScreen extends StatefulWidget {
  const BucketObjectPreviewScreen({
    super.key,
    required this.target,
    required this.objectKey,
    this.presignGetUrl = signing.presignGetUrl,
  });

  final S3BackupTarget target;
  final String objectKey;

  /// Overridable for tests so they never make a real network call.
  final Future<Uri> Function({
    required S3BackupTarget target,
    required String key,
  })
  presignGetUrl;

  @override
  State<BucketObjectPreviewScreen> createState() =>
      _BucketObjectPreviewScreenState();
}

class _BucketObjectPreviewScreenState extends State<BucketObjectPreviewScreen> {
  Uri? _url;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final url = await widget.presignGetUrl(
        target: widget.target,
        key: widget.objectKey,
      );
      if (!mounted) return;
      setState(() => _url = url);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  bool get _isImage {
    final lower = widget.objectKey.toLowerCase();
    return _imageExtensions.any(lower.endsWith);
  }

  String get _fileName => widget.objectKey.contains('/')
      ? widget.objectKey.substring(widget.objectKey.lastIndexOf('/') + 1)
      : widget.objectKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final url = _url;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(_fileName, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white))
            : url == null
            ? const CircularProgressIndicator()
            : _isImage
            ? InteractiveViewer(
                child: Image.network(
                  url.toString(),
                  errorBuilder: (context, error, stackTrace) =>
                      _openExternally(l10n, url),
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : const CircularProgressIndicator(),
                ),
              )
            : _openExternally(l10n, url),
      ),
    );
  }

  Widget _openExternally(AppLocalizations l10n, Uri url) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.insert_drive_file_outlined,
          color: Colors.grey,
          size: 48,
        ),
        const SizedBox(height: 12),
        Text(
          l10n.bucketPreviewUnsupported,
          style: const TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => launchUrl(url, mode: LaunchMode.externalApplication),
          child: Text(l10n.bucketPreviewOpenExternally),
        ),
      ],
    );
  }
}

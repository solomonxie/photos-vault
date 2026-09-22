import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../settings/bucket_location.dart';
import 'album_index.dart';
import 'gallery.dart';
import 'private_lifecycle.dart';

/// One hidden photo, full size, fetched and decrypted on demand.
///
/// There is no local copy to fall back on: the carrier in the bucket is
/// the photo. So this says plainly when it cannot reach it, rather than
/// showing an empty frame that looks like a missing file.
class VaultPhotoScreen extends StatefulWidget {
  const VaultPhotoScreen({
    super.key,
    required this.gallery,
    required this.entry,
  });

  final VaultGallery gallery;
  final IndexEntry entry;

  @override
  State<VaultPhotoScreen> createState() => _VaultPhotoScreenState();
}

class _VaultPhotoScreenState extends State<VaultPhotoScreen>
    with WidgetsBindingObserver, PrivateScreenLifecycle {
  Uint8List? _bytes;
  var _tried = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await widget.gallery.original(widget.entry);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _tried = true;
    });
  }

  /// The same two ways out the library's share sheet offers, since a
  /// hidden photo is the one that most often gets asked "where is this,
  /// exactly". Both point at the carrier: the ordinary-looking photo the
  /// bucket holds, not the one on screen.
  ///
  /// Leaving for the browser backgrounds the app, which closes the album —
  /// the code is cheap to type again, and an album left open behind a
  /// browser tab is the thing this whole screen exists to prevent.
  Future<void> _showShareSheet() async {
    final l10n = AppLocalizations.of(context)!;
    final key = widget.entry.objectKey;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              showObjectInBucketBrowser(context, objectKey: key);
            },
            child: Text(l10n.bucketShowInBucket),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(sheetContext).pop();
              openObjectInSystemBrowser(context, objectKey: key);
            },
            child: Text(l10n.bucketOpenInBrowser),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bytes = _bytes;
    return withPrivacyCover(
      CupertinoPageScaffold(
        backgroundColor: CupertinoColors.black,
        navigationBar: CupertinoNavigationBar(
          middle: Text(widget.entry.name),
          backgroundColor: const Color(0xFF1C1C1E),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            onPressed: _showShareSheet,
            child: const Icon(CupertinoIcons.share, size: 22),
          ),
        ),
        child: SafeArea(
          child: Center(
            child: bytes != null
                ? InteractiveViewer(
                    maxScale: 6,
                    child: Image.memory(bytes, fit: BoxFit.contain),
                  )
                : _tried
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      l10n.vaultNeedsNetwork,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: CupertinoColors.systemGrey),
                    ),
                  )
                : const CupertinoActivityIndicator(),
          ),
        ),
      ),
    );
  }
}

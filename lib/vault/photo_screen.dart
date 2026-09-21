import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
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

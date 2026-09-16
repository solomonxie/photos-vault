import 'dart:io';

import 'package:flutter/cupertino.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';

/// A person's profile picture — resolved on demand from their
/// `avatarLocalId` (one of their own tagged photos, not a separate upload).
/// Falls back to a plain person glyph until resolved or if there's none.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.assetRecordStore,
    required this.localId,
    this.size = 64,
  });

  final AssetRecordStore assetRecordStore;
  final String? localId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final id = localId;
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: id == null
            ? _placeholder()
            : FutureBuilder<AssetRecord?>(
                future: assetRecordStore.getByLocalId(id),
                builder: (context, snapshot) {
                  final record = snapshot.data;
                  if (record == null) return _placeholder();
                  final path = record.sourcePath;
                  if (path != null) {
                    return Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          _placeholder(),
                    );
                  }
                  if (record.sourceType == AssetSourceType.photoManager) {
                    return PhotoManagerThumbnail(assetId: record.localId);
                  }
                  return _placeholder();
                },
              ),
      ),
    );
  }

  Widget _placeholder() => ColoredBox(
    color: CupertinoColors.systemGrey4,
    child: Icon(
      CupertinoIcons.person_fill,
      size: size * 0.6,
      color: CupertinoColors.white,
    ),
  );
}

import 'dart:io';

import 'package:flutter/cupertino.dart';

import '../photos/person.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';

/// A person's profile picture — resolved on demand from their
/// `avatarLocalId` (one of their own tagged photos, not a separate upload),
/// cropped to [face] when the photo is a group shot and only part of it is
/// them. Falls back to a plain person glyph until resolved or if there's
/// none.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.assetRecordStore,
    required this.localId,
    this.face,
    this.size = 64,
  });

  final AssetRecordStore assetRecordStore;
  final String? localId;

  /// Which part of the photo is this person — see [Person.avatarFace].
  /// Null shows the whole photo, centre-cropped to the circle.
  final FaceRect? face;
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
                    return _cropped(
                      Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            _placeholder(),
                      ),
                    );
                  }
                  if (record.sourceType == AssetSourceType.photoManager) {
                    return _cropped(
                      PhotoManagerThumbnail(assetId: record.localId),
                    );
                  }
                  return _placeholder();
                },
              ),
      ),
    );
  }

  /// Blows the photo up and slides it so the face fills the circle —
  /// cheaper than decoding and re-encoding a crop, and it keeps working if
  /// the source is a thumbnail that hasn't loaded yet.
  Widget _cropped(Widget image) {
    final rect = face;
    if (rect == null || rect.width <= 0 || rect.height <= 0) return image;
    // A face box hugs the features; widened so the circle holds a head.
    const padding = 0.6;
    final side =
        (rect.width > rect.height ? rect.width : rect.height) *
        (1 + padding * 2);
    final scale = 1 / side.clamp(0.02, 1.0);
    return ClipRect(
      child: Transform.scale(
        scale: scale,
        alignment: Alignment(
          ((rect.x + rect.width / 2) * 2 - 1).clamp(-1.0, 1.0),
          ((rect.y + rect.height / 2) * 2 - 1).clamp(-1.0, 1.0),
        ),
        child: image,
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

import 'package:flutter/cupertino.dart';

import '../photos/person.dart';
import '../storage/asset_record_store.dart';
import 'person_avatar.dart';

/// One face waiting for a name, drawn like a person's card so the two read
/// as the same kind of thing — a circle you tap. The dashed-feeling grey
/// ring is the only difference: this one is a question.
class UnnamedFaceCard extends StatelessWidget {
  const UnnamedFaceCard({
    super.key,
    required this.face,
    required this.assetRecordStore,
    required this.label,
    required this.onTap,
    this.size = 88,
  });

  final UnnamedFace face;
  final AssetRecordStore assetRecordStore;
  final String label;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: CupertinoColors.systemGrey, width: 1.5),
          ),
          padding: const EdgeInsets.all(2),
          child: PersonAvatar(
            assetRecordStore: assetRecordStore,
            localId: face.localId,
            face: face.face,
            size: size,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 13,
            color: CupertinoColors.systemGrey,
          ),
        ),
        // The pile behind this face, drawn where a named person's photo
        // count goes.
        if (face.alike > 1)
          Text(
            '${face.alike}',
            style: const TextStyle(
              fontSize: 12,
              color: CupertinoColors.systemGrey2,
            ),
          ),
      ],
    ),
  );
}

import 'package:flutter/cupertino.dart';

import '../l10n/app_localizations.dart';
import '../storage/asset_record_store.dart';
import 'asset_grid.dart';

/// The two groupings the library can always answer for itself — no row in
/// the album table, nothing to add to them or remove from them.
///
/// They get a coloured cover rather than their newest photo. An album
/// somebody made is *about* its contents, so the newest one in it is a
/// fair picture of it; "Favourites" and "Videos" are about a property, and
/// the newest video in the library says nothing about the album beyond
/// what the label already says. A fixed cover also stops the two cards
/// re-skinning themselves every time a photo is taken — which is the one
/// thing a shelf you navigate by shape should never do.
///
/// A chosen cover still wins: see [coverStateKey].
enum BuiltInAlbum {
  favorites(
    id: 'builtin:favorites',
    icon: CupertinoIcons.heart_fill,
    from: Color(0xFFC2185B),
    to: Color(0xFFFF8BA7),
  ),
  videos(
    id: 'builtin:videos',
    icon: CupertinoIcons.play_fill,
    from: Color(0xFF3730A3),
    to: Color(0xFF22B8CF),
  );

  const BuiltInAlbum({
    required this.id,
    required this.icon,
    required this.from,
    required this.to,
  });

  final String id;
  final IconData icon;

  /// Top-left and bottom-right of the cover's gradient. Saturated enough
  /// that a white glyph clears contrast on either, which is what lets one
  /// pair of colours serve light and dark mode instead of four.
  final Color from;
  final Color to;

  /// Where a chosen cover is filed. App state rather than the album table:
  /// these two have no row there, and giving them one would mean storing a
  /// membership list as well — a second, staler answer to a question the
  /// library already answers.
  String get coverStateKey => 'cover:$id';
}

/// The photo the user picked for [album], or null for the coloured
/// default.
Future<String?> builtInAlbumCover(
  AssetRecordStore store,
  BuiltInAlbum album,
) async {
  final chosen = await store.getAppState(album.coverStateKey);
  // Empty is how "put the colour back" is stored — app state has no
  // delete, and a key that reads back as itself is one less thing to keep
  // two implementations of.
  return (chosen == null || chosen.isEmpty) ? null : chosen;
}

/// [localId] null puts the coloured default back.
Future<void> setBuiltInAlbumCover(
  AssetRecordStore store,
  BuiltInAlbum album,
  String? localId,
) => store.setAppState(album.coverStateKey, localId ?? '');

/// The tile actions for choosing a built-in album's cover: "Use as Album
/// Cover", or — on the photo that already *is* the cover — the way back to
/// the colour. Empty when this screen isn't one of the built-in albums.
///
/// Shared so the two screens that are one (Favourites and Videos) offer
/// the same thing in the same place, rather than each growing its own
/// half of it.
List<TileAction> coverActions(
  AppLocalizations l10n, {
  required bool enabled,
  required bool isCover,
  required VoidCallback onUse,
  required VoidCallback onDefault,
}) => [
  if (enabled)
    isCover
        ? TileAction(
            icon: CupertinoIcons.circle_grid_hex,
            label: l10n.albumUseDefaultCover,
            onPressed: onDefault,
          )
        : TileAction(
            icon: CupertinoIcons.rectangle_on_rectangle,
            label: l10n.albumUseAsCover,
            onPressed: onUse,
          ),
];

/// The coloured default: the album's own symbol on its gradient.
class BuiltInAlbumCoverArt extends StatelessWidget {
  const BuiltInAlbumCoverArt(this.album, {super.key});

  final BuiltInAlbum album;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [album.from, album.to],
      ),
    ),
    child: Center(
      child: Icon(album.icon, color: CupertinoColors.white, size: 34),
    ),
  );
}

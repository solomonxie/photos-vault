/// A user-visible grouping of assets — Photos' "Albums". Membership is a
/// many-to-many join ([AlbumStore]'s `album_asset` table) kept separate from
/// [AssetRecord] itself, since one asset can sit in several albums.
class Album {
  const Album({
    required this.id,
    required this.name,
    required this.createdAt,
    this.isDemo = false,
  });

  final String id;
  final String name;
  final DateTime createdAt;

  /// Part of the bundled demo set (see `DemoAssetsService`) — deleting it is
  /// allowed, and "Reset Demo Data" in Settings brings it right back with
  /// the same [id], so its membership can be reseeded idempotently.
  final bool isDemo;
}

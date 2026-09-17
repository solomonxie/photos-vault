/// A user-visible grouping of assets — Photos' "Albums". Membership is a
/// many-to-many join ([AlbumStore]'s `album_asset` table) kept separate from
/// [AssetRecord] itself, since one asset can sit in several albums.
class Album {
  const Album({
    required this.id,
    required this.name,
    required this.createdAt,
    this.isDemo = false,
    this.description = '',
    this.tags = const [],
  });

  final String id;
  final String name;
  final DateTime createdAt;

  /// Part of the bundled demo set (see `DemoAssetsService`) — deleting it is
  /// allowed, and "Reset Demo Data" in Settings brings it right back with
  /// the same [id], so its membership can be reseeded idempotently.
  final bool isDemo;

  /// The album's own note and tags — what the *set* is, as opposed to what
  /// any one photo in it is. "Kyoto, October" is a sentence about the trip,
  /// and repeating it on four hundred photos says it four hundred times.
  final String description;
  final List<String> tags;

  Album copyWith({String? name, String? description, List<String>? tags}) =>
      Album(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        isDemo: isDemo,
        description: description ?? this.description,
        tags: tags ?? this.tags,
      );
}

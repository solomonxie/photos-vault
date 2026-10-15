import '../photos/asset_removal.dart' show isInBin;
import '../storage/asset_record.dart';
import 'built_in_album.dart';

/// Everything the library screen derives from [AssetRecordStore.listAll],
/// in one pass, once per change of it.
///
/// On the UI isolate, knowingly: an `Isolate.run` would have to copy every
/// record across first, which on 20k records measured 14–60 ms against
/// well under a millisecond for this pass. Nothing here sorts the whole
/// library — `listAll` is already in grid order.
class LibraryIndex {
  LibraryIndex._({
    required this.all,
    required this.active,
    required this.videos,
    required this.favorites,
    required this.recentlyAdded,
    required this.places,
    required this.deletedCount,
  });

  static final empty = LibraryIndex.of(const [], DateTime(0));

  factory LibraryIndex.of(List<AssetRecord> all, DateTime now) {
    final active = <AssetRecord>[];
    final videos = <AssetRecord>[];
    final favorites = <AssetRecord>[];
    final recent = <AssetRecord>[];
    final groups = <String, List<AssetRecord>>{};
    final since = now.subtract(BuiltInAlbum.recentWindow);
    var deleted = 0;
    for (final r in all) {
      if (isInBin(r)) deleted++;
      if (!r.isVisibleInLibrary) continue;
      active.add(r);
      if (r.countsAsVideo) videos.add(r);
      if (r.isFavorite) favorites.add(r);
      if (r.addedAt.isAfter(since)) recent.add(r);
      final place = r.location;
      if (place != null && place.isNotEmpty) {
        (groups[place] ??= []).add(r);
      }
    }
    recent.sort((a, b) => a.addedAt.compareTo(b.addedAt));
    // Biggest place first: the one you have five hundred photos of is the
    // one you mean.
    final byPlace = groups.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    return LibraryIndex._(
      all: all,
      active: active,
      videos: videos,
      favorites: favorites,
      recentlyAdded: recent,
      places: {for (final e in byPlace) e.key: e.value},
      deletedCount: deleted,
    );
  }

  final List<AssetRecord> all;

  /// What home shows, oldest first.
  final List<AssetRecord> active;
  final List<AssetRecord> videos;
  final List<AssetRecord> favorites;
  final List<AssetRecord> recentlyAdded;
  final Map<String, List<AssetRecord>> places;
  final int deletedCount;
}

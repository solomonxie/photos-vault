import 'package:flutter/foundation.dart' show visibleForTesting;

import '../photos/asset_removal.dart' show isInBin;
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'built_in_album.dart';
import 'photo_grid_layout.dart';

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
    required this.home,
    required this.archived,
    required this.videos,
    required this.favorites,
    required this.recentlyAdded,
    required this.places,
    required this.deletedCount,
    required this.since,
  });

  static final empty = LibraryIndex.of(const [], DateTime(0));

  factory LibraryIndex.of(List<AssetRecord> all, DateTime now) {
    final active = <AssetRecord>[];
    final home = <AssetRecord>[];
    final archived = <AssetRecord>[];
    final videos = <AssetRecord>[];
    final favorites = <AssetRecord>[];
    final recent = <AssetRecord>[];
    final groups = <String, List<AssetRecord>>{};
    final since = now.subtract(BuiltInAlbum.recentWindow);
    var deleted = 0;
    for (final r in all) {
      if (isInBin(r)) deleted++;
      if (!r.inLibraryViews) continue;
      active.add(r);
      (r.isArchived ? archived : home).add(r);
      if (r.countsAsVideo) videos.add(r);
      if (r.isFavorite) favorites.add(r);
      if (r.addedAt.isAfter(since)) recent.add(r);
      final place = r.location;
      if (place != null && place.isNotEmpty) {
        (groups[place] ??= []).add(r);
      }
    }
    recent.sort(_byArrival);
    return _byList[all] = LibraryIndex._(
      all: all,
      active: active,
      home: home,
      archived: archived,
      videos: videos,
      favorites: favorites,
      recentlyAdded: recent,
      places: _bySize(groups),
      deletedCount: deleted,
      since: since,
    );
  }

  /// The index of [all]: the one already worked out for that list, else
  /// [prev] patched by [changes] (see [AssetRecordStore.changesBetween]),
  /// else a full pass.
  factory LibraryIndex.after(
    LibraryIndex? prev,
    List<AssetRecord> all,
    List<RecordChange>? changes,
    DateTime now,
  ) {
    final known = _byList[all];
    if (known != null) return known;
    if (prev != null && changes != null) {
      final patched = patch(prev, all, changes, now);
      if (patched != null) return _byList[all] = patched;
    }
    return LibraryIndex.of(all, now);
  }

  /// The index of [all], shared: what the library screen already worked
  /// out, or one pass now.
  static LibraryIndex forList(List<AssetRecord> all) =>
      _byList[all] ?? LibraryIndex.of(all, DateTime.now());

  static final _byList = Expando<LibraryIndex>();

  /// Above this many changed records a full pass is about as cheap as
  /// patching: each move out of or into a list shifts it.
  static const patchLimit = 256;

  /// [prev] with [changes] applied, list by list, each copied only when a
  /// change touches it. Null when a change doesn't line up with [prev]
  /// (the caller's lists weren't the store's), or there are too many.
  ///
  /// Every list is in a total order (date then id; arrival then that),
  /// so a record's place is found by binary search and the result equals
  /// [LibraryIndex.of] of the same records.
  @visibleForTesting
  static LibraryIndex? patch(
    LibraryIndex prev,
    List<AssetRecord> all,
    List<RecordChange> changes,
    DateTime now,
  ) {
    if (changes.length > patchLimit) return null;
    final since = now.subtract(BuiltInAlbum.recentWindow);
    // A clock set back widens the window: records [prev] left out are due.
    if (since.isBefore(prev.since)) return null;
    List<AssetRecord>? active;
    List<AssetRecord>? home;
    List<AssetRecord>? archived;
    var homeShifted = false;
    List<AssetRecord>? videos;
    List<AssetRecord>? favorites;
    List<AssetRecord>? recent;
    Map<String, List<AssetRecord>>? places;
    final copiedPlaces = <String>{};
    var regroup = false;
    var shifted = false;
    var deleted = prev.deletedCount;

    for (final (:before, :after) in changes) {
      if (before != null && isInBin(before)) deleted--;
      if (after != null && isInBin(after)) deleted++;
      final out = before != null && before.inLibraryViews ? before : null;
      final into = after != null && after.inLibraryViews ? after : null;
      if (out == null && into == null) continue;

      if (out == null || into == null || recordOrder(out, into) != 0) {
        shifted = true;
      }
      if (!editSorted(active ??= [...prev.active], out, into, recordOrder)) {
        return null;
      }
      AssetRecord? only(bool Function(AssetRecord) keep, AssetRecord? r) =>
          r != null && keep(r) ? r : null;
      final homeOut = only((r) => !r.isArchived, out);
      final homeIn = only((r) => !r.isArchived, into);
      if (homeOut != null || homeIn != null) {
        if (homeOut == null ||
            homeIn == null ||
            recordOrder(homeOut, homeIn) != 0) {
          homeShifted = true;
        }
        if (!editSorted(
          home ??= [...prev.home],
          homeOut,
          homeIn,
          recordOrder,
        )) {
          return null;
        }
      }
      final archivedOut = only((r) => r.isArchived, out);
      final archivedIn = only((r) => r.isArchived, into);
      if ((archivedOut != null || archivedIn != null) &&
          !editSorted(
            archived ??= [...prev.archived],
            archivedOut,
            archivedIn,
            recordOrder,
          )) {
        return null;
      }
      final videoOut = only((r) => r.countsAsVideo, out);
      final videoIn = only((r) => r.countsAsVideo, into);
      if ((videoOut != null || videoIn != null) &&
          !editSorted(
            videos ??= [...prev.videos],
            videoOut,
            videoIn,
            recordOrder,
          )) {
        return null;
      }
      final favOut = only((r) => r.isFavorite, out);
      final favIn = only((r) => r.isFavorite, into);
      if ((favOut != null || favIn != null) &&
          !editSorted(
            favorites ??= [...prev.favorites],
            favOut,
            favIn,
            recordOrder,
          )) {
        return null;
      }
      final newOut = only((r) => r.addedAt.isAfter(since), out);
      final newIn = only((r) => r.addedAt.isAfter(since), into);
      if (newOut != null || newIn != null) {
        if (!editSorted(
          recent ??= [...prev.recentlyAdded],
          newOut,
          newIn,
          _byArrival,
        )) {
          return null;
        }
      }
      final placeOut = _placeOf(out);
      final placeIn = _placeOf(into);
      if (placeOut != null || placeIn != null) {
        final map = places ??= {...prev.places};
        List<AssetRecord> group(String place) {
          if (copiedPlaces.add(place)) {
            map[place] = [...?map[place]];
          }
          return map[place]!;
        }

        if (placeOut == placeIn) {
          if (!editSorted(group(placeOut!), out, into, recordOrder)) {
            return null;
          }
          if (recordOrder(out!, into!) != 0) regroup = true;
        } else {
          regroup = true;
          if (placeOut != null) {
            final g = group(placeOut);
            if (!editSorted(g, out, null, recordOrder)) return null;
            if (g.isEmpty) map.remove(placeOut);
          }
          if (placeIn != null &&
              !editSorted(group(placeIn), null, into, recordOrder)) {
            return null;
          }
        }
      }
    }

    // The window moves with the clock as well as with the records.
    final arrived = recent ?? prev.recentlyAdded;
    var keep = 0;
    while (keep < arrived.length && !arrived[keep].addedAt.isAfter(since)) {
      keep++;
    }
    if (keep > 0) recent = arrived.sublist(keep);

    if (active != null && !shifted) {
      PhotoGridLayout.markSameShape(active, prev.active);
    }
    if (home != null && !homeShifted) {
      PhotoGridLayout.markSameShape(home, prev.home);
    }
    return LibraryIndex._(
      all: all,
      active: active ?? prev.active,
      home: home ?? prev.home,
      archived: archived ?? prev.archived,
      videos: videos ?? prev.videos,
      favorites: favorites ?? prev.favorites,
      recentlyAdded: recent ?? prev.recentlyAdded,
      places: places == null
          ? prev.places
          : regroup
          ? _bySize(places)
          : places,
      deletedCount: deleted,
      since: since,
    );
  }

  static String? _placeOf(AssetRecord? r) {
    final place = r?.location;
    return place != null && place.isNotEmpty ? place : null;
  }

  /// Biggest place first: the one you have five hundred photos of is the
  /// one you mean. Ties by their oldest photo, as they were first met.
  static Map<String, List<AssetRecord>> _bySize(
    Map<String, List<AssetRecord>> groups,
  ) {
    final byPlace = groups.entries.toList()
      ..sort((a, b) {
        final bySize = b.value.length.compareTo(a.value.length);
        return bySize != 0 ? bySize : recordOrder(a.value.first, b.value.first);
      });
    return {for (final e in byPlace) e.key: e.value};
  }

  static int _byArrival(AssetRecord a, AssetRecord b) {
    final at = a.addedAt.compareTo(b.addedAt);
    return at != 0 ? at : recordOrder(a, b);
  }

  final List<AssetRecord> all;

  /// Every visible record, oldest first: what albums, people and search
  /// draw from.
  final List<AssetRecord> active;

  /// What the library grid shows: [active] less [archived].
  final List<AssetRecord> home;
  final List<AssetRecord> archived;
  final List<AssetRecord> videos;
  final List<AssetRecord> favorites;
  final List<AssetRecord> recentlyAdded;
  final Map<String, List<AssetRecord>> places;
  final int deletedCount;

  /// Where [recentlyAdded]'s window began.
  final DateTime since;
}

/// [list] (sorted by [order]) with [out] taken out and [into] put in. In
/// place when both sort the same. False when [out] isn't in [list].
bool editSorted(
  List<AssetRecord> list,
  AssetRecord? out,
  AssetRecord? into,
  Comparator<AssetRecord> order,
) {
  var at = -1;
  if (out != null) {
    at = indexIn(list, out, order);
    if (at == -1) return false;
  }
  if (out != null && into != null && order(out, into) == 0) {
    list[at] = into;
    return true;
  }
  if (at != -1) list.removeAt(at);
  if (into != null) list.insert(_lowerBound(list, into, order), into);
  return true;
}

/// Where [record]'s id sits in [list] (sorted by [order]), or -1.
int indexIn(
  List<AssetRecord> list,
  AssetRecord record,
  Comparator<AssetRecord> order,
) {
  final at = _lowerBound(list, record, order);
  return at < list.length && list[at].localId == record.localId ? at : -1;
}

int _lowerBound(
  List<AssetRecord> list,
  AssetRecord record,
  Comparator<AssetRecord> order,
) {
  var lo = 0;
  var hi = list.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (order(list[mid], record) < 0) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// Each album's visible records in grid order, from one pass over
/// [active]. [albumsOf] is photo id to album ids.
Map<String, List<AssetRecord>> albumRecordsOf(
  Iterable<String> albumIds,
  Map<String, List<String>> albumsOf,
  List<AssetRecord> active,
) {
  final out = {for (final id in albumIds) id: <AssetRecord>[]};
  for (final record in active) {
    for (final albumId in albumsOf[record.localId] ?? const <String>[]) {
      out[albumId]?.add(record);
    }
  }
  return out;
}

/// [albumRecordsOf] after [changes], with the memberships unchanged:
/// only albums holding a changed photo get a new list. Null when a change
/// doesn't line up with [prev].
Map<String, List<AssetRecord>>? patchAlbumRecords(
  Map<String, List<AssetRecord>> prev,
  Map<String, List<String>> albumsOf,
  List<RecordChange> changes,
) {
  Map<String, List<AssetRecord>>? out;
  final copied = <String>{};
  for (final (:before, :after) in changes) {
    final id = (before ?? after)!.localId;
    final albums = albumsOf[id];
    if (albums == null) continue;
    final leaving = before != null && before.isVisibleInLibrary ? before : null;
    final into = after != null && after.isVisibleInLibrary ? after : null;
    if (leaving == null && into == null) continue;
    for (final albumId in albums) {
      final map = out ??= {...prev};
      final list = map[albumId];
      if (list == null) continue;
      if (copied.add(albumId)) map[albumId] = [...list];
      if (!editSorted(map[albumId]!, leaving, into, recordOrder)) return null;
    }
  }
  return out ?? prev;
}

/// Whether any of [changes] shows, hides, adds or removes a photo in
/// [ids] — what moves a person's count or first photo.
bool movesAnyOf(Set<String> ids, List<RecordChange> changes) {
  for (final (:before, :after) in changes) {
    final id = (before ?? after)!.localId;
    if (!ids.contains(id)) continue;
    if ((before?.isVisibleInLibrary ?? false) !=
        (after?.isVisibleInLibrary ?? false)) {
      return true;
    }
  }
  return false;
}

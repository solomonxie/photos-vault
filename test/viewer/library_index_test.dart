import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/viewer/library_index.dart';
import 'package:photos_vault/viewer/photo_grid_layout.dart';

final _now = DateTime(2026, 10, 17, 12);

AssetRecord _record(
  String id, {
  required DateTime taken,
  DateTime? added,
  bool video = false,
  String? place,
}) => AssetRecord(
  localId: id,
  contentHash: id,
  platform: 'ios',
  createdAt: taken,
  updatedAt: taken,
  addedAt: added,
  isVideo: video,
  location: place,
);

/// A library and what changed, as the store would hand them over.
class _Library {
  _Library(this.records);

  List<AssetRecord> records;

  List<RecordChange> apply(Map<String, AssetRecord?> edits) {
    final byId = {for (final r in records) r.localId: r};
    final changes = <RecordChange>[];
    for (final MapEntry(key: id, value: next) in edits.entries) {
      changes.add((before: byId[id], after: next));
      if (next == null) {
        byId.remove(id);
      } else {
        byId[id] = next;
      }
    }
    records = List.unmodifiable(byId.values.toList()..sort(recordOrder));
    return changes;
  }
}

void _expectSame(LibraryIndex a, LibraryIndex b) {
  List<String> ids(List<AssetRecord> list) => [for (final r in list) r.localId];
  expect(ids(a.active), ids(b.active), reason: 'active');
  expect(a.active, b.active, reason: 'active instances');
  expect(a.videos, b.videos, reason: 'videos');
  expect(a.favorites, b.favorites, reason: 'favorites');
  expect(a.recentlyAdded, b.recentlyAdded, reason: 'recent');
  expect(a.places.keys.toList(), b.places.keys.toList(), reason: 'places');
  for (final key in a.places.keys) {
    expect(a.places[key], b.places[key], reason: 'place $key');
  }
  expect(a.deletedCount, b.deletedCount, reason: 'bin');
}

void main() {
  group('LibraryIndex.after', () {
    test('patched from a few changes, it is what a full pass gives', () {
      final rng = Random(8);
      final places = ['Kyoto', 'Paris', 'Oslo', null];
      AssetRecord random(String id) => _record(
        id,
        taken: DateTime(2020).add(Duration(hours: rng.nextInt(2000))),
        added: _now.subtract(Duration(days: rng.nextInt(60))),
        video: rng.nextInt(5) == 0,
        place: places[rng.nextInt(places.length)],
      );
      final library = _Library(
        List.unmodifiable(
          <AssetRecord>[for (var i = 0; i < 300; i++) random('photo:$i')]
            ..sort(recordOrder),
        ),
      );
      var index = LibraryIndex.of(library.records, _now);
      const albumIds = ['one', 'two', 'three'];
      final albumsOf = {
        for (var i = 0; i < 400; i += 3)
          'photo:$i': [albumIds[i % 3], if (i % 2 == 0) albumIds[(i + 1) % 3]],
      };
      var albums = albumRecordsOf(albumIds, albumsOf, index.active);
      var next = 300;
      for (var round = 0; round < 200; round++) {
        final edits = <String, AssetRecord?>{};
        for (var k = rng.nextInt(6); k >= 0; k--) {
          final op = rng.nextInt(9);
          if (op == 6) {
            final id = 'photo:${next++}';
            edits[id] = random(id);
            continue;
          }
          final pick = library.records[rng.nextInt(library.records.length)];
          final base = edits[pick.localId] ?? pick;
          edits[pick.localId] = switch (op) {
            0 => base.withFavorite(!base.isFavorite),
            1 => base.withHidden(!base.isHidden),
            2 => base.withDeletedAt(base.isDeleted ? null : _now),
            3 => base.withCreatedAt(
              base.createdAt.add(Duration(hours: rng.nextInt(300) - 150)),
            ),
            4 => base.withLocation(places[rng.nextInt(places.length)]),
            5 => null,
            7 => base.withTags(['t$round']),
            _ => base.withPasscodeHash(base.passcodeHash == null ? 'h' : null),
          };
        }
        final changes = library.apply(edits);
        final at = _now.add(Duration(hours: round));
        final patched = LibraryIndex.patch(
          index,
          library.records,
          changes,
          at,
        )!;
        _expectSame(patched, LibraryIndex.of(library.records, at));
        index = patched;
        albums = patchAlbumRecords(albums, albumsOf, changes)!;
        expect(albums, albumRecordsOf(albumIds, albumsOf, patched.active));
      }
    });

    test('a heart moves no place: the grid keeps its layout', () {
      final a = _record('a', taken: DateTime(2024));
      final b = _record('b', taken: DateTime(2025));
      final library = _Library(List.unmodifiable([a, b]));
      final before = LibraryIndex.of(library.records, _now);
      final changes = library.apply({'b': b.withFavorite(true)});

      final after = LibraryIndex.after(before, library.records, changes, _now);

      expect(after.favorites.map((r) => r.localId), ['b']);
      expect(identical(after.active[0], a), isTrue);
      expect(identical(after.videos, before.videos), isTrue);
      expect(PhotoGridLayout.sameShape(after.active, before.active), isTrue);
      final layout = PhotoGridLayout.of(records: before.active, width: 400);
      final reused = layout.withRecords(after.active);
      expect(identical(reused.sections, layout.sections), isTrue);
      expect(reused.records[1].isFavorite, isTrue);
    });

    test('a re-dated photo is a new layout', () {
      final a = _record('a', taken: DateTime(2024));
      final library = _Library(List.unmodifiable([a]));
      final before = LibraryIndex.of(library.records, _now);
      final changes = library.apply({'a': a.withCreatedAt(DateTime(2023))});

      final after = LibraryIndex.after(before, library.records, changes, _now);

      expect(PhotoGridLayout.sameShape(after.active, before.active), isFalse);
    });

    test('a photo past the Recently Added window leaves it', () {
      final a = _record('a', taken: DateTime(2024), added: _now);
      final b = _record('b', taken: DateTime(2025), added: _now);
      final library = _Library(List.unmodifiable([a, b]));
      final before = LibraryIndex.of(library.records, _now);
      final changes = library.apply({'b': b.withFavorite(true)});
      final later = _now.add(const Duration(days: 40));

      final after = LibraryIndex.after(before, library.records, changes, later);

      expect(after.recentlyAdded, isEmpty);
    });

    test('changes that do not line up: a full pass', () {
      final a = _record('a', taken: DateTime(2024));
      final before = LibraryIndex.of(const [], _now);
      final all = List<AssetRecord>.unmodifiable([a]);

      final after = LibraryIndex.after(before, all, [
        (before: _record('zzz', taken: DateTime(2020)), after: null),
      ], _now);

      expect(after.active, [a]);
    });

    test('forList shares the index already worked out', () {
      final all = List<AssetRecord>.unmodifiable([
        _record('a', taken: DateTime(2024)).withFavorite(true),
      ]);
      final index = LibraryIndex.of(all, _now);
      expect(identical(LibraryIndex.forList(all), index), isTrue);
    });
  });

  group('album records', () {
    test('patched, only albums holding a changed photo change', () {
      final a = _record('a', taken: DateTime(2024));
      final b = _record('b', taken: DateTime(2025));
      final c = _record('c', taken: DateTime(2026));
      final library = _Library(List.unmodifiable([a, b, c]));
      final albumsOf = {
        'a': ['one'],
        'b': ['one', 'two'],
        'c': ['three'],
      };
      final before = albumRecordsOf(
        ['one', 'two', 'three'],
        albumsOf,
        library.records,
      );
      final changes = library.apply({
        'b': b.withHidden(true),
        'c': c.withFavorite(true),
      });

      final after = patchAlbumRecords(before, albumsOf, changes)!;

      expect(
        after,
        albumRecordsOf(
          ['one', 'two', 'three'],
          albumsOf,
          [
            for (final r in library.records)
              if (r.isVisibleInLibrary) r,
          ],
        ),
      );
      expect(after['two'], isEmpty);
      expect(identical(after['three']!.single, library.records[2]), isTrue);
    });

    test('untouched: the same lists', () {
      final a = _record('a', taken: DateTime(2024));
      final library = _Library(List.unmodifiable([a]));
      final before = albumRecordsOf(['one'], const {}, library.records);
      final changes = library.apply({'a': a.withFavorite(true)});
      expect(
        identical(patchAlbumRecords(before, const {}, changes), before),
        isTrue,
      );
    });
  });

  test('movesAnyOf: a hide of a tagged photo, not a heart', () {
    final a = _record('a', taken: DateTime(2024));
    expect(
      movesAnyOf({'a'}, [(before: a, after: a.withFavorite(true))]),
      isFalse,
    );
    expect(movesAnyOf({'a'}, [(before: a, after: a.withHidden(true))]), isTrue);
    expect(
      movesAnyOf({'b'}, [(before: a, after: a.withHidden(true))]),
      isFalse,
    );
    expect(movesAnyOf({'a'}, [(before: null, after: a)]), isTrue);
  });

  group('search', () {
    test('texts are kept per record: a new list redoes only new records', () {
      final a = _record('a', taken: DateTime(2024)).withTags(['Kyoto']);
      final b = _record('b', taken: DateTime(2025)).withDescription('Dawn');
      final first = SearchTexts.of([a, b])!;
      final second = SearchTexts.of([a, b.withDescription('Dusk')])!;
      expect(identical(first[0], second[0]), isTrue);
      expect(second[1], contains('dusk'));
    });

    test('too many to make inline: left to warm', () async {
      final many = [
        for (var i = 0; i <= SearchTexts.inlineLimit; i++)
          _record('m$i', taken: DateTime(2020)).withDescription('n$i'),
      ];
      expect(SearchTexts.of(many), isNull);
      await SearchTexts.warm(many);
      expect(SearchTexts.of(many)![7], searchTextOf(many[7]));
    });

    test('matches narrow from an earlier query, and back again', () {
      final texts = ['kyoto temple', 'kyiv', 'tokyo', 'oslo'];
      final matches = SearchMatches(texts);
      List<int> naive(String q) => [
        for (var i = 0; i < texts.length; i++)
          if (texts[i].contains(q)) i,
      ];
      for (final q in ['k', 'ky', 'kyo', 'kyot', 'kyo', 'ky', 'o', 'yo', 'x']) {
        expect(matches.of(q), naive(q), reason: q);
      }
    });
  });
}

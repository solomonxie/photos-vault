import 'dart:io';

import 'package:photos_vault/storage/album.dart';
import 'package:photos_vault/storage/album_store.dart';

/// Pure-Dart, in-memory stand-in for [AlbumStore] — for widget tests, same
/// rationale as `fake_asset_record_store.dart`: keeps real `sqflite_common_ffi`
/// out of `testWidgets`' fake-async zone.
class FakeAlbumStore implements AlbumStore {
  final _albums = <String, Album>{};
  final _members = <String, Set<String>>{};

  @override
  Future<void> close() async {}

  @override
  Future<Album> upsert({required String id, required String name}) async {
    final existing = _albums[id];
    if (existing != null) return existing;
    final album = Album(id: id, name: name, createdAt: DateTime.now());
    _albums[id] = album;
    return album;
  }

  @override
  Future<void> update(Album album) async => _albums[album.id] = album;

  @override
  Future<Set<String>> allTags() async => {
    for (final album in _albums.values) ...album.tags,
  };

  var _nextId = 0;

  @override
  String newId() => 'album-${_nextId++}';

  @override
  Future<Album?> getById(String id) async => _albums[id];

  @override
  Future<List<Album>> listAll() async =>
      _albums.values.toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<void> addAssets(String albumId, Iterable<String> localIds) async {
    _members.putIfAbsent(albumId, () => {}).addAll(localIds);
  }

  @override
  Future<void> removeAsset(String albumId, String localId) async {
    _members[albumId]?.remove(localId);
  }

  @override
  Future<List<String>> localIdsIn(String albumId) async =>
      _members[albumId]?.toList() ?? const [];

  @override
  Future<void> remove(String albumId) async {
    _albums.remove(albumId);
    _members.remove(albumId);
  }

  /// No file and no log: these fakes are maps, and the tier-1 copy has
  /// nothing to copy. `LocalVault` treats both as "nothing to snapshot".
  @override
  Future<File?> checkpointedFile() async => null;

  @override
  Future<int> changeMark() async => 0;

  @override
  Future<List<Map<String, Object?>>> changeLogRows() async => const [];
}

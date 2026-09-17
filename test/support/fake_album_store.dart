import 'package:bring_your_own_photos/storage/album.dart';
import 'package:bring_your_own_photos/storage/album_store.dart';

/// Pure-Dart, in-memory stand-in for [AlbumStore] — for widget tests, same
/// rationale as `fake_asset_record_store.dart`: keeps real `sqflite_common_ffi`
/// out of `testWidgets`' fake-async zone.
class FakeAlbumStore implements AlbumStore {
  final _albums = <String, Album>{};
  final _members = <String, Set<String>>{};

  @override
  Future<void> close() async {}

  @override
  Future<Album> upsert({
    required String id,
    required String name,
    bool isDemo = false,
  }) async {
    final existing = _albums[id];
    if (existing != null) return existing;
    final album = Album(
      id: id,
      name: name,
      createdAt: DateTime.now(),
      isDemo: isDemo,
    );
    _albums[id] = album;
    return album;
  }

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
}

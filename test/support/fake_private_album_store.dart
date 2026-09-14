import 'package:back_your_own_photos/storage/private_album.dart';
import 'package:back_your_own_photos/storage/private_album_store.dart';

/// Pure-Dart, in-memory stand-in for [PrivateAlbumStore] — for widget tests,
/// same rationale as `fake_asset_record_store.dart`.
class FakePrivateAlbumStore implements PrivateAlbumStore {
  final _albums = <String, PrivateAlbum>{};
  final _members = <String, Map<String, bool>>{};

  @override
  Future<void> close() async {}

  @override
  Future<PrivateAlbum?> find(String passcode) => findById(PrivateAlbumStore.hashOf(passcode));

  @override
  Future<PrivateAlbum?> findById(String id) async => _albums[id];

  @override
  Future<PrivateAlbum> ensure(String passcode) => ensureById(PrivateAlbumStore.hashOf(passcode));

  @override
  Future<PrivateAlbum> ensureById(String id) async {
    final existing = _albums[id];
    if (existing != null) return existing;
    final album = PrivateAlbum(id: id, createdAt: DateTime.now());
    _albums[id] = album;
    return album;
  }

  @override
  Future<void> addAssets(String albumId, Iterable<String> localIds, {required bool moved}) async {
    final members = _members.putIfAbsent(albumId, () => {});
    for (final id in localIds) {
      members[id] = moved;
    }
  }

  @override
  Future<void> removeAsset(String albumId, String localId) async {
    _members[albumId]?.remove(localId);
  }

  @override
  Future<List<String>> localIdsIn(String albumId) async => _members[albumId]?.keys.toList() ?? const [];

  @override
  Future<List<String>> movedLocalIdsIn(String albumId) async =>
      _members[albumId]?.entries.where((e) => e.value).map((e) => e.key).toList() ?? const [];

  @override
  Future<void> remove(String albumId) async {
    _albums.remove(albumId);
    _members.remove(albumId);
  }
}

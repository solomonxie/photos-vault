/// A passcode-gated hidden folder (Utilities' "Hidden" row). [id] is the
/// SHA-256 hash of the 4-digit passcode that unlocks it — see
/// `private_album_store.dart` and DESIGN.md's "Private Albums" section.
class PrivateAlbum {
  const PrivateAlbum({required this.id, required this.createdAt});

  final String id;
  final DateTime createdAt;
}

/// One note on an album — hidden (`../vault/hidden_notes.dart`, sealed) or
/// ordinary (`album_store.dart`).
class Note {
  const Note({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String text;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// Where one album's notes are kept.
abstract interface class NoteBook {
  /// Newest first.
  Future<List<Note>> list();

  /// Adds a note, or replaces [existing]'s text keeping its creation time.
  Future<Note> save(String text, {Note? existing});

  Future<void> delete(String id);
}

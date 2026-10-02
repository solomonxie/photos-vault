import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../photos/person_detail.dart';
import '../storage/asset_record_store.dart';
import 'cipher.dart';
import 'keys.dart';

class HiddenNote {
  const HiddenNote({
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

/// The notes kept in one hidden album.
///
/// In sqlite, which rides to the bucket in every snapshot, so nothing is
/// stored in the clear: the text is sealed with the album key, and the row
/// names its album by a tag keyed on that key rather than by the passcode
/// hash. A wrong code derives another key, another tag, and no notes.
class HiddenNotes {
  HiddenNotes({
    required this.store,
    required this.keys,
    PersonDetailSeal? seal,
    Uuid? uuid,
  }) : _seal = seal ?? PersonDetailSeal(),
       _uuid = uuid ?? const Uuid();

  final AssetRecordStore store;
  final AlbumKeys keys;
  final PersonDetailSeal _seal;
  final Uuid _uuid;

  String get _tag => base64Url.encode(
    vaultHmac(keys.carrier.macKey, utf8.encode('hidden-notes')),
  );

  /// Newest first. A row these keys can't open is skipped, not shown.
  Future<List<HiddenNote>> list() async {
    final rows = await store.hiddenNoteRows(_tag);
    return [
      for (final row in rows)
        if (_seal.openJson(row['payload'] as String, keys)?['text']
            case final String text)
          HiddenNote(
            id: row['id'] as String,
            text: text,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              row['created_at'] as int,
            ),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              row['updated_at'] as int,
            ),
          ),
    ];
  }

  /// Adds a note, or replaces [existing]'s text keeping its creation time.
  Future<HiddenNote> save(String text, {HiddenNote? existing}) async {
    // Milliseconds, as stored, so what this returns is what [list] reads.
    final now = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
    );
    final note = HiddenNote(
      id: existing?.id ?? _uuid.v4(),
      text: text,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    await store.putHiddenNote(
      id: note.id,
      albumTag: _tag,
      payload: _seal.sealJson({'text': text}, keys),
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
    );
    return note;
  }

  Future<void> delete(String id) => store.removeHiddenNote(id);
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/vault/hidden_notes.dart';
import 'package:photos_vault/vault/keys.dart';

import '../support/fake_asset_record_store.dart';

AlbumKeys _keys(int seed) => AlbumKeys(
  albumKey: Uint8List.fromList(List.generate(32, (i) => (i + seed) % 256)),
  entry: PassphraseEntry(
    id: 'e$seed',
    salt: Uint8List(16),
    verifier: Uint8List(32),
    hint: '',
  ),
);

void main() {
  test('add, edit and delete, with both timestamps kept', () async {
    final store = FakeAssetRecordStore();
    final notes = HiddenNotes(store: store, keys: _keys(1));

    final added = await notes.save('flight AS 841');
    final edited = await notes.save('flight AS 842', existing: added);

    final listed = await notes.list();
    expect(listed.single.text, 'flight AS 842');
    expect(listed.single.createdAt, added.createdAt);
    expect(listed.single.updatedAt, edited.updatedAt);

    await notes.delete(added.id);
    expect(await notes.list(), isEmpty);
  });

  test('stored sealed, and another album code sees nothing', () async {
    final store = FakeAssetRecordStore();
    await HiddenNotes(store: store, keys: _keys(1)).save('secret');

    final row = store.hiddenNotes.values.single;
    expect(row['payload'], isNot(contains('secret')));
    expect(await HiddenNotes(store: store, keys: _keys(2)).list(), isEmpty);
  });
}

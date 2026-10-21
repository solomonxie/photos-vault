import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/viewer/built_in_album.dart';

import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

void main() {
  test('album notes, built-in albums\' too, survive a restore', () async {
    final albums = FakeAlbumStore();
    await albums.upsert(id: 'a1', name: 'Kyoto');
    await albums.noteBook('a1').save('Temples');
    await albums
        .noteBook(BuiltInAlbum.favorites.id)
        .save('https://example.com');
    final snapshot = await AppSnapshotIo(
      assetRecordStore: FakeAssetRecordStore(),
      albumStore: albums,
      personStore: FakePersonStore(),
    ).export();
    expect(snapshot.summary.albums, 1);

    final restored = FakeAlbumStore();
    await AppSnapshotIo(
      assetRecordStore: FakeAssetRecordStore(),
      albumStore: restored,
      personStore: FakePersonStore(),
    ).import(AppSnapshot.decode(snapshot.encode())!);

    expect((await restored.listAll()).map((a) => a.id), ['a1']);
    expect((await restored.notes('a1')).single.text, 'Temples');
    expect(
      (await restored.notes(BuiltInAlbum.favorites.id)).single.text,
      'https://example.com',
    );
  });
}

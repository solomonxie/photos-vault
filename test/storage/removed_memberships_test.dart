import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/storage/album_store.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('a permanent delete is remembered until forgotten', () async {
    final store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    await store.upsert(localId: 'manual:a', contentHash: 'a', platform: 'ios');
    await store.upsert(localId: 'manual:b', contentHash: 'b', platform: 'ios');

    await store.remove('manual:a');
    expect(await store.removedIds(), {'manual:a'});

    await store.forgetRemoved({'manual:a'});
    expect(await store.removedIds(), isEmpty);
  });

  test('albums let go of deleted photos, and of them as covers', () async {
    final albums = AlbumStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(albums.close);
    final album = await albums.upsert(id: 'a1', name: 'Trip');
    await albums.addAssets('a1', ['x', 'y', 'z']);
    await albums.update(album.copyWith(coverLocalId: 'x'));

    await albums.forgetAssets({'x', 'z'});

    expect(await albums.localIdsIn('a1'), ['y']);
    expect((await albums.listAll()).single.coverLocalId, isNull);
  });

  test('people let go of deleted photos, and of them as avatars', () async {
    final people = PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(people.close);
    final mia = await people.create(name: 'Mia');
    await people.addAssets(mia.id, ['x', 'y']);
    expect((await people.getById(mia.id))!.avatarLocalId, 'x');

    await people.forgetAssets({'x'});

    expect(await people.localIdsIn(mia.id), ['y']);
    expect((await people.getById(mia.id))!.avatarLocalId, isNull);
  });
}

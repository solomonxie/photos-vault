import 'package:back_your_own_photos/storage/private_album_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  PrivateAlbumStore newStore() {
    final store = PrivateAlbumStore(databaseFactory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.close);
    return store;
  }

  test('find returns null for a passcode never created', () async {
    final store = newStore();

    expect(await store.find('1234'), isNull);
  });

  test('ensure creates the album on first use and is idempotent after', () async {
    final store = newStore();

    final first = await store.ensure('1234');
    final second = await store.ensure('1234');

    expect(second.id, first.id);
    expect(await store.find('1234'), isNotNull);
  });

  test('different passcodes hash to different album ids', () async {
    final store = newStore();

    final a = await store.ensure('1234');
    final b = await store.ensure('5678');

    expect(a.id, isNot(b.id));
  });

  test('addAssets tracks a moved flag per membership row', () async {
    final store = newStore();
    final album = await store.ensure('1234');

    await store.addAssets(album.id, ['moved-1'], moved: true);
    await store.addAssets(album.id, ['copied-1'], moved: false);

    expect(await store.localIdsIn(album.id), unorderedEquals(['moved-1', 'copied-1']));
    expect(await store.movedLocalIdsIn(album.id), ['moved-1']);
  });

  test('removeAsset drops one member without affecting the rest', () async {
    final store = newStore();
    final album = await store.ensure('1234');
    await store.addAssets(album.id, ['p1', 'p2'], moved: true);

    await store.removeAsset(album.id, 'p1');

    expect(await store.localIdsIn(album.id), ['p2']);
  });

  test('remove deletes the album and its membership', () async {
    final store = newStore();
    final album = await store.ensure('1234');
    await store.addAssets(album.id, ['p1'], moved: true);

    await store.remove(album.id);

    expect(await store.findById(album.id), isNull);
    expect(await store.localIdsIn(album.id), isEmpty);
  });
}

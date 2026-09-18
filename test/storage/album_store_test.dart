import 'package:photos_vault/storage/album_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  AlbumStore newStore() {
    final store = AlbumStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return store;
  }

  test(
    'upsert creates an album, and is idempotent for an already-tracked id',
    () async {
      final store = newStore();

      final first = await store.upsert(id: 'a1', name: 'Nature', isDemo: true);
      final second = await store.upsert(
        id: 'a1',
        name: 'Renamed',
        isDemo: false,
      );

      expect(second.name, first.name);
      expect(second.isDemo, first.isDemo);
      expect(await store.listAll(), hasLength(1));
    },
  );

  test(
    'addAssets / localIdsIn track membership, ignoring duplicates',
    () async {
      final store = newStore();
      await store.upsert(id: 'a1', name: 'Nature');

      await store.addAssets('a1', ['p1', 'p2']);
      await store.addAssets('a1', ['p2', 'p3']);

      expect(await store.localIdsIn('a1'), unorderedEquals(['p1', 'p2', 'p3']));
    },
  );

  test('removeAsset drops one member without affecting the rest', () async {
    final store = newStore();
    await store.upsert(id: 'a1', name: 'Nature');
    await store.addAssets('a1', ['p1', 'p2']);

    await store.removeAsset('a1', 'p1');

    expect(await store.localIdsIn('a1'), ['p2']);
  });

  test('remove deletes the album and its membership', () async {
    final store = newStore();
    await store.upsert(id: 'a1', name: 'Nature');
    await store.addAssets('a1', ['p1']);

    await store.remove('a1');

    expect(await store.getById('a1'), isNull);
    expect(await store.localIdsIn('a1'), isEmpty);
  });

  test('listAll orders albums by creation', () async {
    final store = newStore();
    await store.upsert(id: 'a1', name: 'First');
    await store.upsert(id: 'a2', name: 'Second');

    final albums = await store.listAll();

    expect(albums.map((a) => a.id), ['a1', 'a2']);
  });
}

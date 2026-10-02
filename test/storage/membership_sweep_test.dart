import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/storage/album_store.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/membership_sweep.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late AssetRecordStore records;
  late AlbumStore albums;
  late PersonStore people;

  setUp(() {
    // Three databases: one shared `:memory:` would hand all three the same.
    final dir = Directory.systemTemp.createTempSync('sweep');
    addTearDown(() => dir.deleteSync(recursive: true));
    records = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: '${dir.path}/records.db',
    );
    albums = AlbumStore(
      databaseFactory: databaseFactoryFfi,
      path: '${dir.path}/albums.db',
    );
    people = PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: '${dir.path}/people.db',
    );
    addTearDown(records.close);
    addTearDown(albums.close);
    addTearDown(people.close);
  });

  Future<int?> sweep() => sweepOrphanMemberships(
    assetRecordStore: records,
    albumStore: albums,
    personStore: people,
  );

  test('drops only photos with no record at all, once', () async {
    await records.upsert(localId: 'kept', contentHash: 'k', platform: 'ios');
    await records.upsert(localId: 'binned', contentHash: 'b', platform: 'ios');
    await records.softDelete('binned');
    final album = await albums.upsert(id: 'a1', name: 'Trip');
    await albums.addAssets('a1', ['kept', 'binned', 'ghost']);
    await albums.update(album.copyWith(coverLocalId: 'ghost'));
    final person = await people.create(name: 'Ann');
    await people.addAssets(person.id, ['kept', 'ghost']);
    await people.update(person.copyWith(avatarLocalId: 'ghost'));

    expect(await sweep(), 1);

    expect((await albums.localIdsIn('a1')).toSet(), {'kept', 'binned'});
    expect((await albums.listAll()).single.coverLocalId, isNull);
    expect(await people.localIdsIn(person.id), ['kept']);
    expect((await people.listAll()).single.avatarLocalId, isNull);

    // Done: a later orphan is the per-delete cleanup's job, not this one's.
    await albums.addAssets('a1', ['ghost2']);
    expect(await sweep(), 0);
    expect(await albums.localIdsIn('a1'), contains('ghost2'));
  });

  test('an empty record store is not proof every photo is gone', () async {
    await albums.upsert(id: 'a1', name: 'Trip');
    await albums.addAssets('a1', ['x']);

    expect(await sweep(), isNull);
    expect(await albums.localIdsIn('a1'), ['x']);
  });

  test('never runs under a snapshot import', () async {
    await records.upsert(localId: 'kept', contentHash: 'k', platform: 'ios');
    await albums.upsert(id: 'a1', name: 'Trip');
    await albums.addAssets('a1', ['arriving']);

    final release = Completer<void>();
    final import = RestoreGuard.run(() => release.future);
    expect(await sweep(), isNull);
    expect(await albums.localIdsIn('a1'), ['arriving']);
    release.complete();
    await import;
  });

  test('drops rows of albums and people that no longer exist', () async {
    await records.upsert(localId: 'kept', contentHash: 'k', platform: 'ios');
    await albums.addAssets('gone-album', ['kept']);
    await people.addAssets('gone-person', ['kept']);

    await sweep();

    expect((await albums.allMemberships())['gone-album'], isNull);
    expect((await people.allMemberships())['gone-person'], isNull);
  });
}

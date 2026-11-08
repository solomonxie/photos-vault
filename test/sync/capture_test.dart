import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/album_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/sync/capture.dart';
import 'package:photos_vault/sync/translate.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<List<String>> _drain(Future<dynamic> Function() open) async {
  final db = await open();
  final rows = await readCaptured(db);
  if (rows.isNotEmpty) await dropCaptured(db, rows.last.n);
  return [
    for (final r in rows)
      for (final c in translate(r.table, r.key, r.kind, r.before, r.after, 0))
        '${c.e}/${c.id} ${c.o.name}${c.f == null ? '' : ' ${c.f}'}${c.x is Map || c.x == null ? '' : '=${c.x}'}',
  ];
}

void main() {
  setUpAll(sqfliteFfiInit);

  test('photo writes are captured in the same database, only while enabled and not applying', () async {
    final store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    final db = await store.syncDatabase();

    await store.upsert(localId: 'A', contentHash: 'h', platform: 'ios');
    await store.setDescription('A', 'before sync was on');
    expect(await _drain(store.syncDatabase), isEmpty);

    await setCapture(db, enabled: true);
    await store.setDescription('A', 'Beach');
    expect(
      await _drain(store.syncDatabase),
      isEmpty,
      reason: 'not in the bucket yet',
    );

    await store.updateDerivative(
      'A',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'originals/A.HEIC',
      ),
    );
    expect(await _drain(store.syncDatabase), [
      'asset/A add',
      'asset/A madd on_devices',
    ], reason: 'on this phone');

    await store.setDescription('A', 'Beach, day 2');
    await store.setFavorite('A', true);
    expect(await _drain(store.syncDatabase), [
      'asset/A set description=Beach, day 2',
      'asset/A set is_favorite=1',
    ]);

    await applyingRemote(
      db,
      (txn) => txn.update('asset_record', {'description': 'from Chrome'}),
    );
    expect(
      await _drain(store.syncDatabase),
      isEmpty,
      reason: 'pulled ops are not sent back',
    );

    await store.setPasscodeHash('A', 'secret');
    await store.setDescription('A', 'private words');
    expect(await _drain(store.syncDatabase), ['asset/A set hidden=true']);

    await store.setPasscodeHash('A', null);
    expect(await _drain(store.syncDatabase), [
      'asset/A add',
      'asset/A madd on_devices',
    ]);
  });

  test('album writes: create, members in and out, delete', () async {
    final albums = AlbumStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(albums.close);
    await setCapture(await albums.syncDatabase(), enabled: true);
    await albums.upsert(id: 'L', name: 'Trip');
    await albums.addAssets('L', ['A', 'B']);
    await albums.removeAsset('L', 'A');
    await albums.remove('L');
    final ops = await _drain(albums.syncDatabase);
    expect(ops.first, 'album/L add');
    expect(
      ops,
      containsAllInOrder([
        'album/L madd members=A',
        'album/L madd members=B',
        'album/L mrem members=A',
      ]),
    );
    expect(ops.last, startsWith('album/L set deleted_at'));
  });
}

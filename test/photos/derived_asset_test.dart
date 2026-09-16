import 'dart:io';
import 'dart:typed_data';

import 'package:bring_your_own_photos/photos/derived_asset.dart';
import 'package:bring_your_own_photos/photos/manual_add.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:bring_your_own_photos/storage/asset_record_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<Directory> Function() tempDir(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    addTearDown(() => dir.delete(recursive: true));
    return () async => dir;
  }

  AssetRecordStore newStore() {
    final store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
      appSupportDirectory: tempDir('derived_asset_support_'),
    );
    addTearDown(store.close);
    return store;
  }

  test(
    'files edited bytes as a new record carrying the source metadata',
    () async {
      final store = newStore();
      final source = await store.upsert(
        localId: 'manual:source',
        contentHash: 'source',
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/source.jpg',
        createdAt: DateTime(2011, 3, 12, 16, 17),
      );
      await store.setDescription(source.localId, 'at the lake');
      await store.setTags(source.localId, ['lake', 'summer']);
      await store.setLocation(source.localId, 'Lake Como');
      await store.setEvent(source.localId, 'Italy 2011');
      await store.setFavorite(source.localId, true);

      final created = await createDerivedAsset(
        source: (await store.getByLocalId(source.localId))!,
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        extension: '.jpg',
        store: store,
        temporaryDirectory: tempDir('derived_asset_staged_'),
        manualAdd: ManualAddService(
          store: store,
          targetDirectory: tempDir('derived_asset_owned_'),
        ),
      );

      expect(created.localId, isNot(source.localId));
      expect(created.sourcePath, isNot(source.sourcePath));
      expect(await File(created.sourcePath!).readAsBytes(), [1, 2, 3, 4]);
      expect(created.createdAt, source.createdAt);
      expect(created.description, 'at the lake');
      expect(created.tags, ['lake', 'summer']);
      expect(created.location, 'Lake Como');
      expect(created.event, 'Italy 2011');
      expect(created.isFavorite, isTrue);

      // The source keeps its own file and its own record.
      final reloaded = await store.getByLocalId(source.localId);
      expect(reloaded!.sourcePath, '/tmp/source.jpg');
    },
  );

  test('keeps a private-album photo inside that album', () async {
    final store = newStore();
    final source = await store.upsert(
      localId: 'manual:private',
      contentHash: 'private',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/private.jpg',
    );
    await store.setPasscodeHash(source.localId, 'hash-1234');

    final created = await createDerivedAsset(
      source: (await store.getByLocalId(source.localId))!,
      bytes: Uint8List.fromList([9]),
      extension: '.jpg',
      store: store,
      temporaryDirectory: tempDir('derived_asset_staged_'),
      manualAdd: ManualAddService(
        store: store,
        targetDirectory: tempDir('derived_asset_owned_'),
      ),
    );

    expect(created.passcodeHash, 'hash-1234');
  });
}

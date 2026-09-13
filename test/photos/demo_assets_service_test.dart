import 'dart:io';

import 'package:back_your_own_photos/photos/demo_assets_service.dart';
import 'package:back_your_own_photos/photos/manual_add.dart';
import 'package:back_your_own_photos/storage/asset_record.dart';
import 'package:back_your_own_photos/storage/asset_record_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  AssetRecordStore newStore() {
    final store = AssetRecordStore(databaseFactory: databaseFactoryFfi, path: inMemoryDatabasePath);
    addTearDown(store.close);
    return store;
  }

  test('addAll enqueues every bundled demo asset as a manual file', () async {
    final store = newStore();
    final service = DemoAssetsService(
      manualAddService: ManualAddService(store: store, targetDirectory: () async => Directory.systemTemp),
      targetDirectory: () async => Directory.systemTemp,
    );

    final added = await service.addAll();

    expect(added, hasLength(DemoAssetsService.assetPaths.length));
    for (final record in added) {
      expect(record.sourceType, AssetSourceType.manualFile);
      expect(record.sourcePath, isNotNull);
    }
    expect(await store.listAll(), hasLength(DemoAssetsService.assetPaths.length));
  });

  test('addAll is a no-op for demo assets already present', () async {
    final store = newStore();
    final service = DemoAssetsService(
      manualAddService: ManualAddService(store: store, targetDirectory: () async => Directory.systemTemp),
      targetDirectory: () async => Directory.systemTemp,
    );

    await service.addAll();
    await service.addAll();

    expect(await store.listAll(), hasLength(DemoAssetsService.assetPaths.length));
  });

  test('addAll re-creates a demo asset that was deleted (reset behavior)', () async {
    final store = newStore();
    final service = DemoAssetsService(
      manualAddService: ManualAddService(store: store, targetDirectory: () async => Directory.systemTemp),
      targetDirectory: () async => Directory.systemTemp,
    );
    await service.addAll();
    final firstRecord = (await store.listAll()).first;

    await store.remove(firstRecord.localId);
    expect(await store.listAll(), hasLength(DemoAssetsService.assetPaths.length - 1));

    await service.addAll();

    expect(await store.listAll(), hasLength(DemoAssetsService.assetPaths.length));
  });
}

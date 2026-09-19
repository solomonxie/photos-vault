import 'dart:io';

import 'package:photos_vault/photos/manual_add.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/test_platform_file.dart';

void main() {
  test('a GIF is filed with the videos without being one', () async {
    // It moves, so it belongs in the Videos album; it decodes, so it must
    // never reach the video player.
    expect(isGifPath('/tmp/party.GIF'), isTrue);
    expect(isGifPath('/tmp/party.jpg'), isFalse);
  });

  setUpAll(sqfliteFfiInit);

  // sqflite_common_ffi caches in-memory DBs by path (singleInstance
  // default), so distinct stores using the same sentinel path leak state
  // across tests unless each is explicitly closed.
  AssetRecordStore newStore() {
    final store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return store;
  }

  Future<Directory> Function() tempTargetDir() {
    final dir = Directory.systemTemp.createTempSync('manual_add_test_');
    addTearDown(() => dir.delete(recursive: true));
    return () async => dir;
  }

  test(
    'enqueueFile copies the file into app-owned storage, hashed from content',
    () async {
      final store = newStore();
      final file = await File(
        '${Directory.systemTemp.path}/manual_add_test.txt',
      ).writeAsString('hello');
      addTearDown(() => file.delete());

      final service = ManualAddService(
        store: store,
        targetDirectory: tempTargetDir(),
      );
      final record = await service.enqueueFile(file.path);

      expect(record.sourceType, AssetSourceType.manualFile);
      expect(record.sourcePath, isNot(file.path));
      expect(await File(record.sourcePath!).readAsString(), 'hello');
      expect(record.localId, 'manual:${record.contentHash}');
    },
  );

  test('re-adding the same content is a no-op, not a duplicate', () async {
    final store = newStore();
    final file = await File(
      '${Directory.systemTemp.path}/manual_add_test_2.txt',
    ).writeAsString('same content');
    addTearDown(() => file.delete());

    final service = ManualAddService(
      store: store,
      targetDirectory: tempTargetDir(),
    );
    await service.enqueueFile(file.path);
    await service.enqueueFile(file.path);

    expect(await store.listAll(), hasLength(1));
  });

  test('pickAndEnqueue enqueues every file returned by the picker', () async {
    final store = newStore();
    final file = await File(
      '${Directory.systemTemp.path}/manual_add_test_3.txt',
    ).writeAsString('picked');
    addTearDown(() => file.delete());

    final service = ManualAddService(
      store: store,
      targetDirectory: tempTargetDir(),
      picker: ({type = FileType.any, allowMultiple = false}) async => [
        TestPlatformFile(file.path),
      ],
    );

    final added = await service.pickAndEnqueue();

    expect(added, hasLength(1));
    expect(await File(added.single.sourcePath!).readAsString(), 'picked');
  });
}

import 'dart:io';

import 'package:photos_vault/photos/library_custody.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import '../support/fake_asset_record_store.dart';

/// Stands in for the photo library: hands back a file for the original,
/// and remembers whether the delete was asked for and allowed.
class _FakeLibrary implements PhotoLibraryService {
  _FakeLibrary({this.original, this.allowDelete = true});

  File? original;
  bool allowDelete;
  var deleteRequests = 0;

  @override
  Future<File?> fileFor(AssetRecord record) async => original;

  @override
  Future<bool> deleteFromLibrary(AssetRecord record) async =>
      (await deleteManyFromLibrary([record])).contains(record.localId);

  /// One call per group, which is one OS prompt per group — [deleteRequests]
  /// counting *calls* rather than photos is the point of the test.
  @override
  Future<Set<String>> deleteManyFromLibrary(List<AssetRecord> records) async {
    deleteRequests++;
    return allowDelete ? {for (final r in records) r.localId} : <String>{};
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('custody');
  });

  tearDown(() => dir.delete(recursive: true));

  Future<File> originalFile(String name) async {
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(List.filled(64, 7));
    return file;
  }

  Future<AssetRecord> tracked(
    FakeAssetRecordStore store, {
    String libraryId = 'PH1',
  }) async {
    await store.upsert(
      localId: 'photo:$libraryId',
      contentHash: libraryId,
      platform: 'ios',
      libraryId: libraryId,
    );
    return (await store.getByLocalId('photo:$libraryId'))!;
  }

  test(
    'hiding copies the original out before Photos is asked to let go',
    () async {
      final store = FakeAssetRecordStore();
      final record = await tracked(store);
      final library = _FakeLibrary(original: await originalFile('IMG_1.jpg'));
      final custody = LibraryCustody(
        store: store,
        library: library,
        directory: () async => dir,
      );

      expect(await custody.takeOut(record), CustodyResult.taken);

      final after = (await store.getByLocalId(record.localId))!;
      expect(after.sourcePath, isNotNull, reason: 'this app holds a copy');
      expect(File(after.sourcePath!).existsSync(), isTrue);
      expect(after.libraryId, isNull, reason: 'Photos no longer has it');
      expect(library.deleteRequests, 1);
    },
  );

  test('no original to copy means nothing is deleted from Photos', () async {
    final store = FakeAssetRecordStore();
    final record = await tracked(store);
    // An iCloud photo that would not come down.
    final library = _FakeLibrary(original: null);
    final custody = LibraryCustody(
      store: store,
      library: library,
      directory: () async => dir,
    );

    expect(await custody.takeOut(record), CustodyResult.failed);
    expect(library.deleteRequests, 0);
    expect((await store.getByLocalId(record.localId))!.libraryId, 'PH1');
  });

  test(
    'declining the OS prompt leaves the photo in Photos, and says so',
    () async {
      final store = FakeAssetRecordStore();
      final record = await tracked(store);
      final library = _FakeLibrary(
        original: await originalFile('IMG_2.jpg'),
        allowDelete: false,
      );
      final custody = LibraryCustody(
        store: store,
        library: library,
        directory: () async => dir,
      );

      expect(
        await custody.takeOut(record),
        CustodyResult.takenButStillInLibrary,
      );
      final after = (await store.getByLocalId(record.localId))!;
      expect(after.sourcePath, isNotNull);
      expect(after.libraryId, 'PH1', reason: 'still the library’s asset');
    },
  );

  test('un-hiding hands the copy back and follows the new asset id', () async {
    final store = FakeAssetRecordStore();
    final record = await tracked(store);
    final library = _FakeLibrary(original: await originalFile('IMG_3.jpg'));
    var saved = 0;
    final custody = LibraryCustody(
      store: store,
      library: library,
      directory: () async => dir,
      saveToLibrary: (file, {required isVideo}) async {
        saved++;
        // PhotoKit cannot undelete: what comes back is a new asset.
        return AssetEntity(id: 'PH2', typeInt: 1, width: 1, height: 1);
      },
    );
    await custody.takeOut(record);
    final hidden = (await store.getByLocalId(record.localId))!;

    expect(await custody.putBack(hidden), CustodyResult.returned);

    expect(saved, 1);
    final after = (await store.getByLocalId(record.localId))!;
    expect(after.libraryId, 'PH2');
    expect(
      after.localId,
      'photo:PH1',
      reason:
          'this app keeps its own name for the photo, so tags and '
          'people stay attached across the round trip',
    );
  });

  test('a photo imported by hand is never pushed into Photos', () async {
    final store = FakeAssetRecordStore();
    await store.upsert(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/tmp/a.jpg',
    );
    final record = (await store.getByLocalId('manual:a'))!;
    var saved = 0;
    final custody = LibraryCustody(
      store: store,
      library: _FakeLibrary(),
      directory: () async => dir,
      saveToLibrary: (file, {required isVideo}) async {
        saved++;
        return null;
      },
    );

    expect(await custody.putBack(record), CustodyResult.returned);
    expect(saved, 0);
  });
}

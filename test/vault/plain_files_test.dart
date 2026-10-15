import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/vault/hidden_transition.dart';
import 'package:photos_vault/vault/plain_files.dart';
import 'package:photos_vault/vault/store.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';

class _Exclusion extends BackupExclusion {
  final excluded = <String>[];

  @override
  Future<bool> exclude(String path) async {
    excluded.add(path);
    return true;
  }
}

void main() {
  late Directory root;
  late FakeAssetRecordStore records;
  late _Exclusion exclusion;
  late PlainFiles plain;

  String plainDir() => p.join(root.path, 'vault', 'plain');

  Future<File> held(String id, String name, {bool live = false}) async {
    final file = File(p.join(root.path, name))..writeAsBytesSync([1, 2, 3]);
    if (live) {
      File(PhotoLibraryService.heldLiveVideoPath(file.path))
          .writeAsBytesSync([4, 5]);
    }
    await records.upsert(
      localId: id,
      contentHash: id,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: file.path,
      isLivePhoto: live,
    );
    return file;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('pv_plain_');
    records = FakeAssetRecordStore();
    exclusion = _Exclusion();
    plain = PlainFiles(
      store: records,
      directory: () async => root,
      exclusion: exclusion,
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  test(
    'a hidden file moves under the excluded dir, named after nothing',
    () async {
      final file = await held('photo:a', 'photo_a-IMG_1234.HEIC', live: true);
      await records.setPasscodeHash('photo:a', 't1:x');

      expect(
        await plain.keep((await records.getByLocalId('photo:a'))!),
        isTrue,
      );

      final moved = (await records.getByLocalId('photo:a'))!.sourcePath!;
      expect(p.dirname(moved), plainDir());
      expect(p.basename(moved), isNot(contains('IMG')));
      expect(p.basename(moved), matches(RegExp(r'^[0-9a-f]{32}\.heic$')));
      expect(exclusion.excluded, [plainDir()]);
      expect(File(moved).readAsBytesSync(), [1, 2, 3]);
      expect(
        File(PhotoLibraryService.heldLiveVideoPath(moved)).existsSync(),
        isTrue,
      );
      expect(file.existsSync(), isFalse);
      expect(
        File(PhotoLibraryService.heldLiveVideoPath(file.path)).existsSync(),
        isFalse,
      );
    },
  );

  test('un-hiding moves it back under the name it had', () async {
    final file = await held('photo:a', 'photo_a-IMG_1234.HEIC', live: true);
    await records.setPasscodeHash('photo:a', 't1:x');
    await plain.keep((await records.getByLocalId('photo:a'))!);
    await records.setPasscodeHash('photo:a', null);

    expect(await plain.release('photo:a'), isTrue);

    final back = (await records.getByLocalId('photo:a'))!.sourcePath!;
    expect(back, file.path);
    expect(File(back).readAsBytesSync(), [1, 2, 3]);
    expect(
      File(PhotoLibraryService.heldLiveVideoPath(back)).existsSync(),
      isTrue,
    );
    expect(Directory(plainDir()).listSync(), isEmpty);
    expect(await records.heldNameOf('photo:a'), isNull);
  });

  test('hide and un-hide through the transition move the files', () async {
    final file = await held('photo:a', 'a.jpg');
    final transition = HiddenTransition(
      store: records,
      loadTargets: () async => const [],
      pendingDeletes: PendingDeletes(store: records),
      analysisStore: FakeAiAnalysisStore(),
      thumbnails: ThumbnailCache(store: records, directory: () async => root),
      plainFiles: plain,
    );

    await transition.markHidden(['photo:a'], 't1:x');
    await transition.settleHide('photo:a');
    final hiddenPath = (await records.getByLocalId('photo:a'))!.sourcePath!;
    expect(p.dirname(hiddenPath), plainDir());

    expect(
      await transition.unhideRecord((await records.getByLocalId('photo:a'))!),
      isTrue,
    );
    final record = (await records.getByLocalId('photo:a'))!;
    expect(record.passcodeHash, isNull);
    expect(record.sourcePath, file.path);
    expect(file.readAsBytesSync(), [1, 2, 3]);
  });

  test('a move a kill cut short is finished, and nothing is lost', () async {
    final file = await held('photo:a', 'photo_a-IMG_1.JPG');
    await held('photo:b', 'photo_b-IMG_2.JPG');
    await records.setPasscodeHash('photo:a', 't1:x');
    await records.setPasscodeHash('photo:b', 't1:x');
    // Killed after the rename, before the row: the row names a file that is
    // already under its new name.
    final target = p.join(
      (await plain.dir()).path,
      PlainFiles.neutralName('photo:a', '.JPG'),
    );
    file.renameSync(target);

    expect(await plain.settleAll(), 2);
    expect((await records.getByLocalId('photo:a'))!.sourcePath, target);
    expect(File(target).readAsBytesSync(), [1, 2, 3]);
    expect(
      p.dirname((await records.getByLocalId('photo:b'))!.sourcePath!),
      plainDir(),
    );
    // Run again: nothing left to do.
    expect(await plain.settleAll(), 0);

    // An un-hide killed after its rename is finished the same way.
    await records.setPasscodeHash('photo:a', null);
    File(target).renameSync(file.path);
    expect(await plain.settleAll(), 1);
    expect((await records.getByLocalId('photo:a'))!.sourcePath, file.path);
    expect(file.existsSync(), isTrue);
  });

  test('a file another row shares is copied, never taken from it', () async {
    final file = await held('photo:a', 'shared.jpg');
    await records.upsert(
      localId: 'photo:b',
      contentHash: 'b',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: file.path,
    );
    await records.setPasscodeHash('photo:a', 't1:x');

    await plain.keep((await records.getByLocalId('photo:a'))!);

    expect(file.existsSync(), isTrue);
    expect((await records.getByLocalId('photo:b'))!.sourcePath, file.path);
    expect(
      File((await records.getByLocalId('photo:a'))!.sourcePath!).existsSync(),
      isTrue,
    );
  });

  test('a file outside the app, or in the vault, is left alone', () async {
    final outside = Directory.systemTemp.createTempSync('pv_outside_');
    addTearDown(() => outside.deleteSync(recursive: true));
    final file = File(p.join(outside.path, 'x.jpg'))..writeAsBytesSync([1]);
    await records.upsert(
      localId: 'photo:x',
      contentHash: 'x',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: file.path,
      passcodeHash: 't1:x',
    );

    expect(await plain.keep((await records.getByLocalId('photo:x'))!), isFalse);
    expect(file.existsSync(), isTrue);
    expect((await records.getByLocalId('photo:x'))!.sourcePath, file.path);
    expect(VaultStore.root, 'vault');
  });
}

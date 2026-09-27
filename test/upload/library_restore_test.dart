import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/library_restore.dart';
import 'package:photos_vault/upload/original_restore.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';

Future<BackupTargetsStore> _oneTarget() async {
  final store = BackupTargetsStore(store: FakeSecureStore());
  await store.add(
    accessKeyId: 'a',
    secretAccessKey: 'b',
    region: 'us-east-1',
    bucket: 'bucket',
    prefix: 'photos/',
  );
  return store;
}

Future<void> _record(
  FakeAssetRecordStore store, {
  required String localId,
  String? thumbnailKey = 'photos/thumbnails/x.jpg',
  String? thumbnailPath,
  DateTime? createdAt,
  String? passcodeHash,
}) async {
  await store.upsert(
    localId: localId,
    contentHash: localId,
    platform: 'ios',
    createdAt: createdAt,
  );
  if (thumbnailKey != null) {
    await store.updateDerivative(
      localId,
      DerivativeKind.thumbnail,
      DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: thumbnailKey,
      ),
    );
  }
  if (thumbnailPath != null) {
    await store.setThumbnailPath(localId, thumbnailPath);
  }
  if (passcodeHash != null) {
    await store.setPasscodeHash(localId, passcodeHash);
  }
}

LibraryRestore _restoreOver(
  FakeAssetRecordStore store,
  BackupTargetsStore targets,
  Directory dir, {
  Future<http.Response> Function(Uri url)? get,
}) => LibraryRestore(
  recordStore: store,
  originals: OriginalRestore(
    targetsStore: targets,
    recordStore: store,
    directory: () async => dir,
    get: get ?? (_) async => http.Response.bytes([1, 2, 3], 200),
  ),
);

void main() {
  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('pv_refill_'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  test('only photos with no picture on the phone are owed one', () async {
    final store = FakeAssetRecordStore();
    await _record(store, localId: 'photo:blank');
    await _record(
      store,
      localId: 'photo:drawn',
      thumbnailPath: '${tempDir.path}/already.jpg',
    );
    // Nothing in the bucket to fetch — small enough that the upload was
    // skipped as not worth a second near-identical object.
    await _record(store, localId: 'photo:nokey', thumbnailKey: null);
    // Hidden photos are not refilled: nothing about them is kept here.
    await _record(store, localId: 'photo:hidden', passcodeHash: 'abc');

    final owed = await _restoreOver(store, await _oneTarget(), tempDir).owed();

    expect(owed.map((r) => r.localId), ['photo:blank']);
  });

  test('fetches the newest first, and says what arrived', () async {
    final store = FakeAssetRecordStore();
    await _record(
      store,
      localId: 'photo:old',
      createdAt: DateTime(2011, 3, 12),
      thumbnailKey: 'photos/thumbnails/old.jpg',
    );
    await _record(
      store,
      localId: 'photo:new',
      createdAt: DateTime(2026, 9, 26),
      thumbnailKey: 'photos/thumbnails/new.jpg',
    );
    final fetched = <String>[];

    final progress = await _restoreOver(
      store,
      await _oneTarget(),
      tempDir,
      get: (url) async {
        fetched.add(url.path);
        return http.Response.bytes([9], 200);
      },
    ).run();

    expect(progress.done, 2);
    expect(progress.failed, 0);
    expect(progress.isFinished, isTrue);
    // The grid opens on the newest photos, so that is the end that fills
    // first — the rest arrives behind what is being looked at.
    expect(fetched.first, endsWith('new.jpg'));
    expect((await store.getByLocalId('photo:new'))!.thumbnailPath, isNotNull);
  });

  test('a fetch that fails is counted, not thrown', () async {
    final store = FakeAssetRecordStore();
    await _record(store, localId: 'photo:1');

    final progress = await _restoreOver(
      store,
      await _oneTarget(),
      tempDir,
      get: (_) async => http.Response('', 500),
    ).run();

    expect(progress.done, 0);
    expect(progress.failed, 1);
    expect(progress.isFinished, isTrue);
  });

  test('reports progress as it goes, not only at the end', () async {
    final store = FakeAssetRecordStore();
    for (var i = 0; i < LibraryRestore.concurrency + 1; i++) {
      await _record(
        store,
        localId: 'photo:$i',
        thumbnailKey: 'photos/thumbnails/$i.jpg',
      );
    }
    final seen = <int>[];

    await _restoreOver(
      store,
      await _oneTarget(),
      tempDir,
    ).run(onProgress: (progress) => seen.add(progress.done));

    // A batch at a time, so the line on screen moves — and not once per
    // file, which on a real library is thirty thousand rebuilds of a grid.
    expect(seen, [LibraryRestore.concurrency, LibraryRestore.concurrency + 1]);
  });
}

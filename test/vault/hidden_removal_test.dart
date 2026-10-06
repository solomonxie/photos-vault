import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/vault/album_index.dart';
import 'package:photos_vault/vault/bucket.dart';
import 'package:photos_vault/vault/hidden_removal.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/store.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';

AlbumKeys _keys() => AlbumKeys(
  albumKey: Uint8List.fromList(List.generate(32, (i) => i)),
  entry: PassphraseEntry(
    id: 'e1',
    salt: Uint8List(16),
    verifier: Uint8List(32),
    hint: '',
  ),
);

IndexEntry _entry(String key) => IndexEntry(
  objectKey: key,
  takenAt: DateTime(2026, 2, 3),
  width: 1,
  height: 1,
  isVideo: false,
);

class _NoExclusion extends BackupExclusion {
  const _NoExclusion();

  @override
  Future<bool> exclude(String path) async => true;
}

void main() {
  late Directory tempDir;
  late Map<String, Uint8List> objects;
  late VaultStore store;
  late VaultBucket bucket;
  late BackupTargetsStore targets;
  late FakeAssetRecordStore records;
  late List<String> deleted;
  late HiddenRemoval removal;
  final keys = _keys();

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('pv_hidden_removal_');
    objects = {};
    deleted = [];
    records = FakeAssetRecordStore();
    store = VaultStore(
      directory: () async => tempDir,
      exclusion: const _NoExclusion(),
    );
    targets = BackupTargetsStore(store: FakeSecureStore());
    await targets.add(
      accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
      secretAccessKey: 'secret',
      region: 'us-east-1',
      bucket: 'my-bucket',
      prefix: 'photos/',
    );
    bucket = VaultBucket(
      targetsStore: targets,
      store: store,
      put: (url, {body}) async {
        objects[url.path] = Uint8List.fromList(body as List<int>);
        return http.Response('', 200);
      },
      get: (url, {headers}) async {
        final bytes = objects.entries
            .where((e) => url.path.endsWith(e.key))
            .map((e) => e.value)
            .firstOrNull;
        return bytes == null
            ? http.Response('', 404)
            : http.Response.bytes(bytes, 200);
      },
    );
    removal = HiddenRemoval(
      store: records,
      targetsStore: targets,
      vaultStore: store,
      bucket: bucket,
      pendingDeletes: PendingDeletes(
        store: records,
        delete: ({required S3BackupTarget target, required String key}) async {
          deleted.add(key);
          return true;
        },
      ),
    );
  });
  tearDown(() => tempDir.deleteSync(recursive: true));

  test('a filed photo leaves the index, this phone and the bucket', () async {
    const gone = 'originals/a.jpg';
    const kept = 'originals/b.jpg';
    await bucket.writeAlbum(
      keys: keys,
      entries: [_entry(gone), _entry(kept)],
      passphrases: [keys.entry],
    );
    await store.putCarrierBytes(keys, gone, Uint8List.fromList([1, 2, 3]));

    expect(await removal.delete(keys: keys, entries: [_entry(gone)]), isTrue);

    final album = await bucket.readAlbum(keys);
    expect(album.entries.map((e) => e.objectKey), [kept]);
    expect(await store.hasCarrier(keys, gone), isFalse);
    await pumpEventQueue();
    expect(deleted, contains('photos/$gone'));
  });

  test('an unfiled hidden record is removed for good, not binned', () async {
    await records.upsert(
      localId: 'photo:x',
      contentHash: 'x',
      platform: 'ios',
      libraryId: null,
    );
    await records.setPasscodeHash('photo:x', 'hash');
    await records.updateDerivative(
      'photo:x',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'photos/originals/photo_x.jpg',
      ),
    );
    final record = (await records.getByLocalId('photo:x'))!;

    await removal.delete(keys: keys, records: [record]);
    await pumpEventQueue();

    expect(await records.getByLocalId('photo:x'), isNull);
    expect(deleted, contains('photos/originals/photo_x.jpg'));
  });
}

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/vault/bucket.dart';
import 'package:photos_vault/vault/hidden_filing.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/object_key.dart';
import 'package:photos_vault/vault/store.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';

class _NoExclusion extends BackupExclusion {
  const _NoExclusion();

  @override
  Future<bool> exclude(String path) async => true;
}

void main() {
  final outbox = Uint8List.fromList(List.generate(32, (i) => 255 - i));
  final keys = AlbumKeys(
    albumKey: Uint8List.fromList(List.generate(32, (i) => i)),
    entry: PassphraseEntry(
      id: 'e1',
      salt: Uint8List(16),
      verifier: Uint8List(32),
      hint: '',
    ),
    outboxKey: outbox,
  );

  late Directory dir;
  late FakeAssetRecordStore records;
  late VaultStore store;
  late VaultBucket bucket;
  late HiddenFiling filing;
  late File plain;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('pv_filing_');
    records = FakeAssetRecordStore();
    store = VaultStore(
      directory: () async => dir,
      exclusion: const _NoExclusion(),
    );
    bucket = VaultBucket(
      // No bucket configured at all.
      targetsStore: BackupTargetsStore(store: FakeSecureStore()),
      store: store,
      put: (url, {body}) => throw StateError('no bucket to put to'),
      get: (url, {headers}) => throw StateError('no bucket to get from'),
    );
    filing = HiddenFiling(
      records: records,
      vaultStore: store,
      bucket: bucket,
      keysFor: (hash) => hash == 'h' ? keys : null,
      passphrases: () async => [keys.entry],
      removeThumbnail: (_) async {},
    );
    plain = File('${dir.path}/IMG_1.jpg')..writeAsBytesSync([1, 2, 3]);
    await records.upsert(
      localId: 'manual:one',
      contentHash: 'c',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: plain.path,
    );
    await records.setPasscodeHash('manual:one', 'h');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('with no bucket, a hidden photo is still filed and its plaintext '
      'goes', () async {
    final record = (await records.getByLocalId('manual:one'))!;
    final key = vaultCarrierKey(record);
    await store.putCarrierBytes(keys, key, Uint8List.fromList([9, 9, 9]));

    expect(await filing.file(record, name: 'Hidden'), isTrue);

    expect(await records.getByLocalId('manual:one'), isNull);
    expect(plain.existsSync(), isFalse);
    final entry = (await bucket.readAlbum(keys)).entries.single;
    expect(entry.objectKey, key);
    expect(entry.hasMotion, isFalse);
    expect(await store.isIndexUnpublished(), isTrue);

    // Owed to the first bucket, and nameable without the album open.
    expect(await store.isUnsent(keys, key), isTrue);
    final sentAs = <String>[];
    await store.sendUnsent(
      outboxKey: (id) async => id == 'e1' ? outbox : null,
      put: (carrier, objectKey) async {
        sentAs.add(objectKey);
        return true;
      },
    );
    expect(sentAs, [key]);
  });

  test('nothing is filed until the carrier exists', () async {
    final record = (await records.getByLocalId('manual:one'))!;

    expect(await filing.file(record, name: 'Hidden'), isFalse);

    expect(await records.getByLocalId('manual:one'), isNotNull);
    expect(plain.existsSync(), isTrue);
  });

  test('nothing is filed while the album is locked', () async {
    final record = (await records.getByLocalId('manual:one'))!;
    await store.putCarrierBytes(
      keys,
      vaultCarrierKey(record),
      Uint8List.fromList([9]),
    );

    await records.setPasscodeHash('manual:one', 'other');
    final locked = (await records.getByLocalId('manual:one'))!;

    expect(await filing.file(locked, name: 'Hidden'), isFalse);
    expect(plain.existsSync(), isTrue);
  });
}

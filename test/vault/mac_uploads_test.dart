import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/upload/signing.dart';
import 'package:photos_vault/vault/mac_uploads.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/memory_bucket.dart';

void main() {
  test('a photo the Mac sent is taken on once the bucket has it; one not '
      'there yet waits for the next run', () async {
    final docs = await Directory.systemTemp.createTemp('mac_uploads_');
    addTearDown(() => docs.delete(recursive: true));
    final records = FakeAssetRecordStore();
    for (final id in ['h1', 'h2']) {
      await records.upsert(localId: id, contentHash: id, platform: 'ios');
      await records.setPasscodeHash(id, 'tag');
    }
    final targets = BackupTargetsStore(store: FakeSecureStore());
    final target = await targets.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'b',
      prefix: 'pv',
    );
    final bucket = MemoryBucket();
    String key(String name) => derivativeKey(
      prefix: target.prefix,
      derivativeDir: 'originals',
      fileName: name,
    );
    bucket.objects[key('c1.jpg')] = Uint8List(3);
    final file = File('${docs.path}/${MacUploads.fileName}')
      ..writeAsStringSync(
        [
          jsonEncode({'localId': 'h1', 'file': 'c1.jpg', 'hash': 'x1'}),
          jsonEncode({'localId': 'h2', 'file': 'c2.jpg', 'hash': 'x2'}),
        ].join('\n'),
      );
    final adopt = MacUploads(
      records: records,
      targets: targets,
      documents: () async => docs,
      ops: bucket,
    );

    expect(await adopt.adopt(), 1);
    final h1 = (await records.getByLocalId('h1'))!
        .stateOf(DerivativeKind.original);
    expect(
      (h1.status, h1.destinationKey, h1.backedUpHash),
      (UploadStatus.uploaded, key('c1.jpg'), 'x1'),
    );
    expect(
      (await records.getByLocalId('h2'))!
          .stateOf(DerivativeKind.original)
          .status,
      UploadStatus.pending,
    );
    expect(file.readAsStringSync(), contains('c2.jpg'));

    bucket.objects[key('c2.jpg')] = Uint8List(3);
    expect(await adopt.adopt(), 1);
    expect(file.existsSync(), isFalse);

    // Sent by the phone meanwhile under its own name: the Mac's copy goes.
    await records.updateDerivative(
      'h1',
      DerivativeKind.original,
      DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: key('phone.jpg'),
      ),
    );
    file.writeAsStringSync(
      jsonEncode({'localId': 'h1', 'file': 'c1.jpg', 'hash': 'x1'}),
    );
    expect(await adopt.adopt(), 0);
    expect(
      (await PendingDeletes(store: records).pending()).map((d) => d.objectKey),
      [key('c1.jpg')],
    );
  });
}

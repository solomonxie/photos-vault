import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/private_album_gate.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  late Directory dir;
  late FakeAssetRecordStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pv_unhide_');
    store = FakeAssetRecordStore();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AssetRecord> hiddenAndBackedUp({String? sourcePath}) async {
    await store.upsert(
      localId: 'manual:a',
      contentHash: 'a',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: sourcePath,
    );
    // What the buckets hold of a hidden photo: its carrier.
    await store.updateDerivative(
      'manual:a',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'originals/carrier.jpg',
      ),
    );
    await store.recordUpload(
      localId: 'manual:a',
      kind: DerivativeKind.original,
      targetId: 't1',
      destinationKey: 'originals/carrier.jpg',
    );
    return (await store.getByLocalId('manual:a'))!;
  }

  test('an un-hidden photo is backed up again, in the clear', () async {
    final file = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
    final record = await hiddenAndBackedUp(sourcePath: file.path);

    await resetBackupAfterUnhide(record, store);

    final after = (await store.getByLocalId('manual:a'))!;
    expect(after.stateOf(DerivativeKind.original).status, UploadStatus.pending);
    expect(after.stateOf(DerivativeKind.original).destinationKey, isNull);
    expect(
      await store.targetsHolding('manual:a', DerivativeKind.original),
      isEmpty,
    );
  });

  test(
    'without the file here, the carrier key is the only copy and stays',
    () async {
      final record = await hiddenAndBackedUp(
        sourcePath: '${dir.path}/missing.jpg',
      );

      await resetBackupAfterUnhide(record, store);

      final after = (await store.getByLocalId('manual:a'))!;
      expect(
        after.stateOf(DerivativeKind.original).destinationKey,
        'originals/carrier.jpg',
      );
    },
  );
}

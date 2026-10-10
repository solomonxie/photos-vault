import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/vault/hidden_backup.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  test(
    'backs up only unlocked albums, and tries a failure once a pass',
    () async {
      final store = FakeAssetRecordStore();
      for (final (id, hash) in [('a', 'open'), ('b', 'open'), ('c', 'shut')]) {
        await store.upsert(
          localId: id,
          contentHash: id,
          platform: 'ios',
          sourceType: AssetSourceType.manualFile,
        );
        await store.setPasscodeHash(id, hash);
      }
      final tried = <String>[];
      final backup = HiddenBackup(
        records: store,
        albums: () => ['open'],
        ready: () async => true,
        backUp: (r) async {
          tried.add(r.localId);
          if (r.localId == 'b') throw Exception('offline');
          await store.updateDerivative(
            r.localId,
            DerivativeKind.original,
            const DerivativeState(status: UploadStatus.uploaded),
          );
        },
      );

      await backup.run();
      expect(tried, ['a', 'b']);
      expect(backup.problems.value.keys, ['b']);

      await backup.run();
      expect(tried, ['a', 'b', 'b']);
    },
  );

  test('with no bucket nothing is tried', () async {
    final store = FakeAssetRecordStore();
    await store.upsert(
      localId: 'a',
      contentHash: 'a',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
    );
    await store.setPasscodeHash('a', 'open');
    var tried = 0;
    await HiddenBackup(
      records: store,
      albums: () => ['open'],
      ready: () async => false,
      backUp: (_) async => tried++,
    ).run();
    expect(tried, 0);
  });
}

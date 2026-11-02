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

  test(
    'several go up at once, and a stop ends the run between photos',
    () async {
      final store = FakeAssetRecordStore();
      for (var i = 0; i < 6; i++) {
        await store.upsert(
          localId: 'p$i',
          contentHash: 'p$i',
          platform: 'ios',
          sourceType: AssetSourceType.manualFile,
        );
        await store.setPasscodeHash('p$i', 'open');
      }
      var running = 0, most = 0, done = 0;
      var stop = false;
      await HiddenBackup(
        records: store,
        albums: () => ['open'],
        ready: () async => true,
        concurrency: 3,
        stopped: () => stop,
        backUp: (r) async {
          running++;
          most = running > most ? running : most;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          running--;
          if (++done == 3) stop = true;
        },
      ).run();
      expect(most, 3);
      // Those already going finish; none starts after the stop.
      expect(done, lessThan(6));
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

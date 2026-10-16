import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_asset_record_store.dart';

/// What the delete paths ask the store, answered the same by the real SQL
/// and by the fake that most delete tests run on. A difference here is a
/// delete test proving something the phone doesn't do.
void main() {
  setUpAll(sqfliteFfiInit);

  final stores = <String, AssetRecordStore Function()>{
    'real': () => AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    ),
    'fake': FakeAssetRecordStore.new,
  };

  for (final MapEntry(key: name, value: make) in stores.entries) {
    group(name, () {
      late AssetRecordStore store;

      setUp(() async {
        store = make();
        for (final id in ['photo:A', 'photo:B']) {
          await store.upsert(localId: id, contentHash: id, platform: 'ios');
        }
      });
      tearDown(() => store.close());

      test('a key held by a row of another photo is held', () async {
        await store.recordUpload(
          localId: 'photo:A',
          kind: DerivativeKind.original,
          targetId: 't1',
          destinationKey: 'originals/a.jpg',
        );
        expect(await store.keyHeldByOthers('originals/a.jpg', 'photo:B'), true);
        expect(await store.keyHeldByOthers('originals/a.jpg', null), true);
        expect(
          await store.keyHeldByOthers('originals/a.jpg', 'photo:A'),
          false,
        );
      });

      test('a key named by a record column is held, for every kind', () async {
        for (final (kind, key) in [
          (DerivativeKind.original, 'originals/b.heic'),
          (DerivativeKind.thumbnail, 'thumbnails/b.jpg'),
          (DerivativeKind.medium, 'medium/b.jpg'),
          (DerivativeKind.livePhoto, 'originals/b.mov'),
        ]) {
          await store.updateDerivative(
            'photo:B',
            kind,
            DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
          );
          expect(await store.keyHeldByOthers(key, 'photo:A'), true);
          expect(await store.keyHeldByOthers(key, 'photo:B'), false);
        }
      });

      test('targetsHolding filters by kind and by source hash', () async {
        await store.recordUpload(
          localId: 'photo:A',
          kind: DerivativeKind.original,
          targetId: 't1',
          destinationKey: 'originals/a.jpg',
          sourceHash: 'h1',
        );
        await store.recordUpload(
          localId: 'photo:A',
          kind: DerivativeKind.original,
          targetId: 't2',
          destinationKey: 'p/originals/a.jpg',
          sourceHash: 'h2',
        );
        expect(await store.targetsHolding('photo:A', DerivativeKind.original), {
          't1': 'originals/a.jpg',
          't2': 'p/originals/a.jpg',
        });
        expect(
          await store.targetsHolding(
            'photo:A',
            DerivativeKind.original,
            sourceHash: 'h2',
          ),
          {'t2': 'p/originals/a.jpg'},
        );
        expect(
          await store.targetsHolding('photo:A', DerivativeKind.thumbnail),
          isEmpty,
        );
      });

      test('forgetting one target leaves the others holding', () async {
        for (final t in ['t1', 't2']) {
          await store.recordUpload(
            localId: 'photo:A',
            kind: DerivativeKind.original,
            targetId: t,
            destinationKey: '$t/a.jpg',
          );
        }
        await store.forgetTargetUpload(
          'photo:A',
          DerivativeKind.original,
          't1',
        );
        expect(await store.targetsHolding('photo:A', DerivativeKind.original), {
          't2': 't2/a.jpg',
        });
        expect(await store.keyHeldByOthers('t1/a.jpg', null), false);
        expect(await store.keyHeldByOthers('t2/a.jpg', null), true);

        await store.forgetUploads('photo:A');
        expect(await store.keyHeldByOthers('t2/a.jpg', null), false);
      });

      test('uploadRows lists every per-bucket row', () async {
        await store.recordUpload(
          localId: 'photo:A',
          kind: DerivativeKind.thumbnail,
          targetId: 't1',
          destinationKey: 'thumbnails/a.jpg',
        );
        final rows = await store.uploadRows();
        expect(rows, hasLength(1));
        expect(rows.single['local_id'], 'photo:A');
        expect(rows.single['kind'], 'thumbnail');
        expect(rows.single['target_id'], 't1');
        expect(rows.single['destination_key'], 'thumbnails/a.jpg');
      });

      test('a removed bucket loses its listing, not its upload rows', () async {
        final at = DateTime.utc(2026);
        for (final t in ['t1', 't2']) {
          await store.replaceBucketObjects(t, [
            BucketObject(targetId: t, key: 'k', size: 1, lastModified: at),
          ]);
        }
        await store.recordUpload(
          localId: 'photo:A',
          kind: DerivativeKind.original,
          targetId: 't1',
          destinationKey: 'k',
        );

        await store.forgetBucketListing('t1');

        expect(await store.isListed('t1', 'k'), false);
        expect(await store.isListed('t2', 'k'), true);
        expect(await store.keyHeldByOthers('k', null), true);
      });
    });
  }
}

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/hidden_transition.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/memory_bucket.dart';
import 'carrier_fixtures.dart';

const _target = S3BackupTarget(
  id: 't1',
  accessKeyId: 'AKIA',
  secretAccessKey: 'secret',
  region: 'us-east-1',
  bucket: 'b',
  prefix: 'p/',
);

final _plain = 'p/originals/20260101120000_${'a' * 32}.jpg';
final _carrier = 'p/originals/20170309082303_${'c' * 32}.jpg';

void main() {
  late FakeAssetRecordStore records;
  late MemoryBucket bucket;
  late PendingDeletes pending;
  late Directory dir;

  HiddenTransition transition() => HiddenTransition(
    store: records,
    loadTargets: () async => const [_target],
    pendingDeletes: pending,
    analysisStore: FakeAiAnalysisStore(),
    thumbnails: ThumbnailCache(store: records),
  );

  DeferredDeletes holds() =>
      DeferredDeletes.untilCarrier(store: records, pending: pending);
  DeferredDeletes deferred() =>
      DeferredDeletes(store: records, pending: pending);

  Future<void> uploaded(String id, String key) async {
    await records.recordUpload(
      localId: id,
      kind: DerivativeKind.original,
      targetId: _target.id,
      destinationKey: key,
    );
    await records.updateDerivative(
      id,
      DerivativeKind.original,
      DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
    );
  }

  Future<void> sync() async {
    await deferred().release(const [_target]);
    await holds().release(const [_target]);
    await pending.drain(const [_target]);
  }

  setUp(() async {
    records = FakeAssetRecordStore();
    bucket = MemoryBucket();
    pending = PendingDeletes(store: records, ops: bucket);
    dir = Directory.systemTemp.createTempSync('pv_transition_');
    final file = File('${dir.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
    await records.upsert(
      localId: 'photo:a',
      contentHash: 'a',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: file.path,
    );
    bucket.objects[_plain] = Uint8List.fromList(List.filled(40, 7));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('hide', () {
    setUp(() => uploaded('photo:a', _plain));

    test(
      'the plain bucket copy stays until the carrier is proven up',
      () async {
        await transition().markHidden(['photo:a'], 'h');
        await transition().settleHide('photo:a');

        expect((await records.getByLocalId('photo:a'))!.passcodeHash, 'h');
        expect(
          await records.targetsHolding('photo:a', DerivativeKind.original),
          isEmpty,
          reason: 'the next backup treats it as never sent',
        );
        expect((await holds().waiting())['photo:a'], isNotEmpty);

        // The carrier upload failed.
        await records.updateDerivative(
          'photo:a',
          DerivativeKind.original,
          const DerivativeState(status: UploadStatus.failed),
        );
        await sync();
        expect(bucket.deleted, isEmpty);
        expect(bucket.objects, contains(_plain));

        // Recorded as landed, but the bucket doesn't have it: still kept.
        await uploaded('photo:a', _carrier);
        await sync();
        expect(bucket.deleted, isEmpty);

        bucket.objects[_carrier] = Uint8List.fromList(List.filled(60, 9));
        await sync();
        expect(bucket.deleted, [_plain]);
        expect(bucket.objects, contains(_carrier));
      },
    );

    test(
      'un-hidden before the carrier lands, the plain copy is kept',
      () async {
        await transition().markHidden(['photo:a'], 'h');
        await transition().settleHide('photo:a');
        final record = (await records.getByLocalId('photo:a'))!;

        expect(await transition().unhideRecord(record), isTrue);
        await uploaded('photo:a', _plain);
        await sync();

        expect(await holds().waiting(), isEmpty);
        expect(bucket.deleted, isEmpty);
        expect((await records.getByLocalId('photo:a'))!.passcodeHash, isNull);
      },
    );

    test('a hide that did not take leaves the bucket alone', () async {
      await transition().markHidden(['photo:a'], 'h');
      await transition().cancelHide('photo:a');

      expect((await records.getByLocalId('photo:a'))!.passcodeHash, isNull);
      expect(await records.targetsHolding('photo:a', DerivativeKind.original), {
        _target.id: _plain,
      });
      expect(records.transitions, isEmpty);
      expect(await holds().waiting(), isEmpty);
    });

    test(
      'a kill before the keys are reset is finished on next launch',
      () async {
        await transition().markHidden(['photo:a'], 'h');
        records.crashAt = 'retract';
        await expectLater(transition().settleHide('photo:a'), throwsStateError);

        // Hidden, journaled, and still naming its plain copy.
        expect(records.transitions['photo:a']!.step, 0);
        expect(
          (await records.getByLocalId('photo:a'))!.isFullyBackedUp,
          isTrue,
        );

        expect(await transition().resume(), 1);

        expect(records.transitions, isEmpty);
        final after = (await records.getByLocalId('photo:a'))!;
        expect(after.passcodeHash, 'h');
        expect(after.isFullyBackedUp, isFalse, reason: 'its carrier is owed');
        expect((await holds().waiting())['photo:a']!.map((t) => t.objectKey), [
          _plain,
        ]);
      },
    );

    test('a kill after the reset loses nothing it owed', () async {
      await transition().markHidden(['photo:a'], 'h');
      records.crashAt = 'close';
      await expectLater(transition().settleHide('photo:a'), throwsStateError);
      expect(records.transitions['photo:a']!.step, 1);

      await transition().resume();

      expect(records.transitions, isEmpty);
      expect((await holds().waiting())['photo:a']!.map((t) => t.objectKey), [
        _plain,
      ]);
      expect(await pending.pending(), isEmpty);
    });
  });

  group('un-hide', () {
    setUp(() async {
      await records.setPasscodeHash('photo:a', 'h');
      await uploaded('photo:a', _carrier);
      bucket.objects[_carrier] = Uint8List.fromList(List.filled(60, 9));
      bucket.objects.remove(_plain);
    });

    test('keys reset and hash cleared together; the carrier waits for the '
        'plain copy to be proven', () async {
      final record = (await records.getByLocalId('photo:a'))!;
      expect(await transition().unhideRecord(record), isTrue);

      final after = (await records.getByLocalId('photo:a'))!;
      expect(after.passcodeHash, isNull);
      expect(after.stateOf(DerivativeKind.original).destinationKey, isNull);
      expect(
        await records.targetsHolding('photo:a', DerivativeKind.original),
        isEmpty,
      );
      final waiting = (await deferred().waiting())['photo:a']!;
      expect(waiting.map((t) => t.objectKey), contains(_carrier));
      expect(waiting.every((t) => t.carrier), isTrue);

      // Recorded as up, but not there: the carrier stays.
      await uploaded('photo:a', _plain);
      await sync();
      expect(bucket.deleted, isEmpty);

      bucket.objects[_plain] = Uint8List.fromList(List.filled(40, 7));
      await sync();
      expect(bucket.deleted, [_carrier]);
    });

    test('with the file gone the keys are still reset; the carrier stays '
        'as the only copy', () async {
      File((await records.getByLocalId('photo:a'))!.sourcePath!).deleteSync();
      final record = (await records.getByLocalId('photo:a'))!;

      await transition().unhideRecord(record);
      await sync();

      final after = (await records.getByLocalId('photo:a'))!;
      expect(after.stateOf(DerivativeKind.original).destinationKey, isNull);
      expect(bucket.deleted, isEmpty);
      expect((await deferred().waiting())['photo:a'], isNotEmpty);
    });

    test('a kill mid-way resumes from the journal', () async {
      final record = (await records.getByLocalId('photo:a'))!;
      records.crashAt = 'retract';
      await expectLater(transition().unhideRecord(record), throwsStateError);

      // Nothing about the photo changed yet: still hidden, still holding
      // its carrier key, so nothing can upload over it.
      final mid = (await records.getByLocalId('photo:a'))!;
      expect(mid.passcodeHash, 'h');
      expect(mid.stateOf(DerivativeKind.original).destinationKey, _carrier);
      expect(records.transitions['photo:a']!.kind, HiddenTransition.unhide);

      await transition().resume();

      final after = (await records.getByLocalId('photo:a'))!;
      expect(after.passcodeHash, isNull);
      expect(after.stateOf(DerivativeKind.original).destinationKey, isNull);
      expect(records.transitions, isEmpty);
      expect(
        (await deferred().waiting())['photo:a']!.map((t) => t.objectKey),
        contains(_carrier),
      );
    });

    test(
      'pre-guard carrier tasks with no flag are refused, nothing goes',
      () async {
        await pending.add([PendingDelete(objectKey: _carrier, targetId: 't1')]);
        // Held by nobody, a real-looking carrier in the bucket.
        await records.forgetUploads('photo:a');
        await records.updateDerivative(
          'photo:a',
          DerivativeKind.original,
          const DerivativeState(),
        );
        bucket.objects[_carrier] = _jpegCarrierLike();

        await pending.drain(const [_target]);

        expect(bucket.deleted, isEmpty);
      },
    );
  });
}

Uint8List _jpegCarrierLike() => buildJpegCarrier(
  cipher: PlatformCipher(),
  keys: CarrierKeys.forAlbum(Uint8List.fromList(List.generate(32, (i) => i))),
  masterSalt: Uint8List.fromList(List.generate(16, (i) => i * 3)),
  decoy: decoyJpeg(),
  thumbnail: Uint8List.fromList(List.generate(3000, (i) => i % 200)),
  original: Uint8List.fromList(List.generate(20000, (i) => i % 250)),
  extension: 'jpg',
  nonce: Uint8List.fromList(List.generate(8, (i) => i + 9)),
  meta: CarrierMeta(
    takenAt: DateTime(2024, 5, 6),
    width: 10,
    height: 20,
    isVideo: false,
  ),
)!;

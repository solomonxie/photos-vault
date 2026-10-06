import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:photos_vault/upload/bucket_flagged.dart';
import 'package:photos_vault/upload/bucket_leftovers.dart';
import 'package:photos_vault/upload/capture_date.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/memory_bucket.dart';

/// A JPEG whose APP1 Exif holds only DateTimeOriginal.
Uint8List exifJpeg(String date) {
  final tiff = BytesBuilder()
    ..add([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0])
    // IFD0: one entry, the Exif IFD pointer.
    ..add([1, 0, 0x69, 0x87, 4, 0, 1, 0, 0, 0, 26, 0, 0, 0, 0, 0, 0, 0])
    // Exif IFD at 26: DateTimeOriginal, ASCII x20 at offset 44.
    ..add([1, 0, 0x03, 0x90, 2, 0, 20, 0, 0, 0, 44, 0, 0, 0, 0, 0, 0, 0])
    ..add([...date.codeUnits, 0]);
  final app1 = [...'Exif'.codeUnits, 0, 0, ...tiff.toBytes()];
  final length = app1.length + 2;
  return Uint8List.fromList([
    0xFF,
    0xD8,
    0xFF,
    0xE1,
    length >> 8,
    length & 0xFF,
    ...app1,
    0xFF,
    0xD9,
  ]);
}

String protocolName(String stamp, String ext) =>
    '${stamp}_${'a' * 31}${stamp.substring(13)}.$ext';

void main() {
  group('rule', () {
    final arrived = DateTime(2026, 10, 3, 9);

    test('a stamp close to arrival with no date of its own is a leftover', () {
      expect(
        isLikelyLeftover(
          nameStamp: DateTime(2026, 10, 2, 22),
          reference: arrived,
          captureDate: null,
        ),
        isTrue,
      );
    });

    test('a camera stamp months before arrival is not', () {
      expect(
        isLikelyLeftover(
          nameStamp: DateTime(2025, 12, 28, 12),
          reference: arrived,
          captureDate: null,
        ),
        isFalse,
      );
    });

    test('a capture date of its own always wins', () {
      expect(
        isLikelyLeftover(
          nameStamp: DateTime(2026, 10, 2, 22),
          reference: arrived,
          captureDate: DateTime(2024, 7, 4),
        ),
        isFalse,
      );
    });
  });

  group('capture dates', () {
    test('EXIF DateTimeOriginal is read from a JPEG header', () {
      expect(
        stillCaptureDate(exifJpeg('2024:07:04 18:30:05')),
        DateTime(2024, 7, 4, 18, 30, 5),
      );
    });

    test('a WebP EXIF chunk is read', () {
      final jpeg = exifJpeg('2023:01:02 03:04:05');
      final exif = jpeg.sublist(6, jpeg.length - 2);
      final chunk = [
        ...'EXIF'.codeUnits,
        ...(ByteData(
          4,
        )..setUint32(0, exif.length, Endian.little)).buffer.asUint8List(),
        ...exif,
        if (exif.length.isOdd) 0,
      ];
      final webp = Uint8List.fromList([
        ...'RIFF'.codeUnits,
        0,
        0,
        0,
        0,
        ...'WEBP'.codeUnits,
        ...chunk,
      ]);
      expect(stillCaptureDate(webp), DateTime(2023, 1, 2, 3, 4, 5));
    });

    test('mvhd creation time is read, and zero is no date', () {
      Uint8List mvhd(int seconds) {
        final b = ByteData(20)
          ..setUint32(0, 20)
          ..setUint32(12, seconds);
        final bytes = b.buffer.asUint8List();
        bytes.setRange(4, 8, 'mvhd'.codeUnits);
        return bytes;
      }

      final when = DateTime.utc(2024, 1, 2, 3, 4, 5);
      final seconds = when.difference(DateTime.utc(1904)).inSeconds;
      expect(mvhdCreationTime(mvhd(seconds)), when.toLocal());
      expect(mvhdCreationTime(mvhd(0)), isNull);
    });

    test('no metadata is no date', () {
      expect(stillCaptureDate(Uint8List(300)), isNull);
    });
  });

  group('detect', () {
    late FakeAssetRecordStore store;
    late BackupTargetsStore targets;
    late S3BackupTarget target;
    late MemoryBucket bucket;

    setUp(() async {
      store = FakeAssetRecordStore();
      targets = BackupTargetsStore(store: FakeSecureStore());
      target = await targets.add(
        accessKeyId: 'a',
        secretAccessKey: 'b',
        region: 'us-east-1',
        bucket: 'b',
        prefix: 'photos-vault/',
      );
      bucket = MemoryBucket();
    });

    Future<void> relist() async {
      final rows = [
        for (final dir in ['originals/', 'thumbnails/'])
          for (final o in (await bucket.listFolder(target, dir))!)
            BucketObject(
              targetId: target.id,
              key: o.key,
              size: o.size,
              lastModified: o.lastModified,
            ),
      ];
      await store.replaceBucketObjects(target.id, rows);
    }

    Future<List<FlaggedObject>> detect() => BucketFlags(store: store).detect(
      inspect: BucketFixer(
        store: store,
        targetsStore: targets,
        passphrases: () async => [],
        ops: bucket,
      ).inspect,
    );

    final plain = Uint8List.fromList(List.generate(4000, (i) => i % 7));

    test('an upload-stamped file with no date of its own is a leftover, '
        'and is never offered as new', () async {
      // MemoryBucket stamps everything 2026-10-03 09:00.
      bucket.objects['photos-vault/originals/${protocolName('20261002220022', 'webp')}'] =
          plain;
      bucket.objects['photos-vault/originals/${protocolName('20251228120340', 'jpg')}'] =
          plain;
      await relist();

      final flagged = await detect();
      final kinds = {for (final f in flagged) f.name.substring(0, 8): f.kind};
      expect(kinds['20261002'], FlagKind.likelyLeftover);
      expect(kinds['20251228'], FlagKind.unclaimed);
    });

    test('a capture date in the file makes it new, and is carried', () async {
      bucket.objects['photos-vault/originals/${protocolName('20261002220022', 'jpg')}'] =
          exifJpeg('2021:05:06 07:08:09');
      await relist();

      final item = (await detect()).single;
      expect(item.kind, FlagKind.unclaimed);
      expect(item.takenAt, DateTime(2021, 5, 6, 7, 8, 9));
    });

    test('an ignored key is not listed at all', () async {
      final key =
          'photos-vault/originals/${protocolName('20251228120340', 'jpg')}';
      bucket.objects[key] = plain;
      await relist();
      await IgnoredBucketKeys(store).addAll([key]);

      expect(await detect(), isEmpty);
    });
  });

  group('sweep', () {
    late FakeAssetRecordStore store;

    Future<String> imported(
      String stamp, {
      bool favorite = false,
      DateTime? lastModified,
    }) async {
      final base = protocolName(stamp, 'webp').split('.').first;
      final localId = 'bucket:$base';
      final key = 'photos-vault/originals/$base.webp';
      await store.upsert(
        localId: localId,
        contentHash: localId,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        createdAt: DateTime(2026, 10, 2),
        addedAt: DateTime(2026, 10, 5, 6),
      );
      await store.updateDerivative(
        localId,
        DerivativeKind.original,
        DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
      );
      if (favorite) await store.setFavorite(localId, true);
      return localId;
    }

    setUp(() => store = FakeAssetRecordStore());

    test('removes untouched upload-stamped imports, keeps the rest, '
        'and ignores their keys from then on', () async {
      final leftover = await imported('20261002220022');
      final favorite = await imported('20261002220023', favorite: true);
      final inAlbum = await imported('20261002220024');
      final camera = await imported('20251228120340');

      final removed = await LeftoverSweep(
        store: store,
        albumMemberships: () async => {
          'a': [inAlbum],
        },
        personMemberships: () async => {},
      ).runOnce();

      expect(removed, 1);
      expect(await store.getByLocalId(leftover), isNull);
      for (final kept in [favorite, inAlbum, camera]) {
        expect(await store.getByLocalId(kept), isNotNull);
      }
      expect(await IgnoredBucketKeys(store).read(), {
        'photos-vault/originals/${leftover.substring(7)}.webp',
      });
    });

    test('runs once', () async {
      await imported('20261002220022');
      final sweep = LeftoverSweep(
        store: store,
        albumMemberships: () async => {},
        personMemberships: () async => {},
      );
      expect(await sweep.runOnce(), 1);
      await imported('20261002220025');
      expect(await sweep.runOnce(), 0);
    });
  });
}

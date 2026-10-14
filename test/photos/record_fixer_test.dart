import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:photos_vault/photos/fix_queue.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/photos/record_fixer.dart';
import 'package:photos_vault/photos/storage_advice.dart';
import 'package:photos_vault/photos/storage_optimizer.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:photos_vault/upload/bucket_flagged.dart';
import 'package:photos_vault/upload/original_restore.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';

void main() {
  late Directory tempDir;
  late FakeAssetRecordStore store;
  late BackupTargetsStore targets;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('pv_record_fixer_');
    store = FakeAssetRecordStore();
    targets = BackupTargetsStore(store: FakeSecureStore());
    await targets.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'bucket',
      prefix: 'photos-vault',
    );
  });
  tearDown(() => tempDir.delete(recursive: true));

  /// A cloud-only record whose original went to [key].
  Future<void> cloudOnly(
    String id, {
    required String key,
    bool video = false,
    String? thumbnail,
    String? libraryId,
  }) async {
    await store.upsert(
      localId: id,
      contentHash: id,
      platform: 'ios',
      isVideo: video,
      libraryId: libraryId,
    );
    await store.updateDerivative(
      id,
      DerivativeKind.original,
      DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
    );
    if (thumbnail != null) await store.setThumbnailPath(id, thumbnail);
    await store.setLocalDeleted(id, true);
  }

  Future<void> listed(List<String> keys) => store.replaceBucketObjects('t', [
    for (final k in keys)
      BucketObject(
        targetId: 't',
        key: k,
        size: 4096,
        lastModified: DateTime(2026),
      ),
  ]);

  RecordFixer fixer({
    Set<String> inPhotos = const {},
    Set<String> inBucket = const {},
    Future<bool> Function(Map<String, Object> args)? frame,
    List<String>? asked,
  }) => RecordFixer(
    store: store,
    thumbnail: OriginalRestore(
      targetsStore: targets,
      recordStore: store,
      directory: () async => tempDir,
      get: (url) async {
        asked?.add(url.path);
        return http.Response('', 404);
      },
      frame: frame ?? (_) async => false,
    ).restoreThumbnail,
    inPhotos: (r) async => inPhotos.contains(r.localId),
    liveOriginal: (stem) async => inBucket.contains(stem)
        ? (targetId: 't', key: 'photos-vault/originals/$stem.heic')
        : null,
    remove: (r) async {
      await store.remove(r.localId);
      return true;
    },
  );

  FixQueue queue(RecordFixer records) => FixQueue(
    store: store,
    advisor: StorageAdvisor(store: store),
    optimizer: StorageOptimizer(
      store: store,
      thumbnails: ThumbnailCache(store: store, directory: () async => tempDir),
      library: PhotoLibraryService(store: FakeAssetRecordStore()),
      backUp: (_) async {},
    ),
    fixer: BucketFixer(
      store: store,
      targetsStore: targets,
      passphrases: () async => const [],
    ),
    refreshBucket: () async {},
    records: records,
  );

  Future<void> drained(FixQueue q) async {
    while (q.running) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('a smaller copy left in Photos is paired with its own original, '
      'not the burst frame beside it', () async {
    final taken = DateTime(2026, 9, 8, 14, 42, 50);
    String picture(String name, {required bool flipped, int width = 90}) {
      final image = img.Image(width: width, height: width * 2 ~/ 3);
      for (final px in image) {
        final v = flipped ? 255 - px.x * 255 ~/ width : px.x * 255 ~/ width;
        px
          ..r = v
          ..g = v
          ..b = px.y * 255 ~/ (width * 2 ~/ 3);
      }
      final file = File('${tempDir.path}/$name.jpg')
        ..writeAsBytesSync(img.encodeJpg(image));
      return file.path;
    }

    Future<void> photo(
      String id, {
      required int width,
      required int height,
      required String thumbnail,
      DateTime? added,
    }) async {
      final key = 'photos-vault/originals/$id.heic';
      await store.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        width: width,
        height: height,
        createdAt: taken,
        addedAt: added ?? taken,
        libraryId: '$id/L0/001',
      );
      await store.updateDerivative(
        id,
        DerivativeKind.original,
        DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
      );
      await store.setThumbnailPath(id, thumbnail);
    }

    final later = taken.add(const Duration(days: 30));
    await photo(
      'a',
      width: 5120,
      height: 3414,
      thumbnail: picture('a', flipped: false),
    );
    await photo(
      'b',
      width: 5120,
      height: 3414,
      thumbnail: picture('b', flipped: true),
    );
    await photo(
      'copy',
      width: 2560,
      height: 1707,
      added: later,
      thumbnail: picture('copy', flipped: true, width: 60),
    );
    await photo(
      'again',
      width: 2560,
      height: 1707,
      added: later,
      thumbnail: picture('again', flipped: true, width: 75),
    );
    await listed([
      for (final id in ['a', 'b', 'copy', 'again'])
        'photos-vault/originals/$id.heic',
    ]);
    final filed = <(String, String, List<String>)>[];
    final f = RecordFixer(
      store: store,
      thumbnail: (_) async => null,
      inPhotos: (_) async => true,
      remove: (_) async => true,
      fileCopies: (pairs, extras) async {
        for (final (:original, :copy) in pairs) {
          filed.add((
            original.localId,
            copy.localId,
            [for (final e in extras) e.localId],
          ));
        }
      },
    );

    final scan = await f.scan();

    expect(scan.leftoverCopies.map((x) => x.asset!.localId), ['b']);
    expect(
      (await f.finishOptimize((await store.getByLocalId('b'))!)).ok,
      isTrue,
    );
    expect(filed.single.$1, 'b');
    expect(filed.single.$3, hasLength(1));
  });

  test('extra copies of an optimized photo are offered for removal, '
      'never the burst frame beside it', () async {
    final taken = DateTime(2026, 9, 8, 14, 42, 50);
    final later = taken.add(const Duration(days: 30));
    String picture(String name, {required bool flipped, int width = 90}) {
      final image = img.Image(width: width, height: width * 2 ~/ 3);
      for (final px in image) {
        final v = flipped ? 255 - px.x * 255 ~/ width : px.x * 255 ~/ width;
        px
          ..r = v
          ..g = v
          ..b = px.y * 255 ~/ (width * 2 ~/ 3);
      }
      final file = File('${tempDir.path}/$name.jpg')
        ..writeAsBytesSync(img.encodeJpg(image));
      return file.path;
    }

    Future<void> photo(
      String id, {
      required bool flipped,
      required int thumbWidth,
      bool optimized = false,
      DateTime? added,
    }) async {
      await store.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        width: 2560,
        height: 1707,
        createdAt: taken,
        addedAt: added ?? taken,
        libraryId: '$id/L0/001',
      );
      await store.updateDerivative(
        id,
        DerivativeKind.original,
        DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'photos-vault/originals/$id.heic',
        ),
      );
      await store.setThumbnailPath(
        id,
        picture(id, flipped: flipped, width: thumbWidth),
      );
      if (optimized) await store.setLocalOptimized(id, true);
    }

    await photo('kept', flipped: true, thumbWidth: 90, optimized: true);
    await photo('frame', flipped: false, thumbWidth: 90, optimized: true);
    await photo('stray', flipped: true, thumbWidth: 60, added: later);
    await photo('stray2', flipped: true, thumbWidth: 75, added: later);
    await listed([
      for (final id in ['kept', 'frame', 'stray', 'stray2'])
        'photos-vault/originals/$id.heic',
    ]);
    final paired = <String>[];
    final extras = <String>[];
    final f = RecordFixer(
      store: store,
      thumbnail: (_) async => null,
      inPhotos: (_) async => true,
      remove: (_) async => true,
      fileCopies: (p, e) async {
        paired.addAll([for (final x in p) x.original.localId]);
        extras.addAll([for (final x in e) x.localId]);
      },
    );

    final scan = await f.scan();

    final flag = scan.leftoverCopies.single;
    expect(flag.asset!.localId, 'kept');
    expect(flag.solutions, [FlagSolution.removeExtraCopies]);
    expect((await f.finishOptimize(flag.asset!)).ok, isTrue);
    expect(paired, isEmpty);
    expect(extras, unorderedEquals(['stray', 'stray2']));
  });

  test('an import of a key since replaced is dropped, its twin kept', () async {
    await cloudOnly(
      'bucket:20210912023824_abc',
      key: 'photos-vault/originals/20210912023824_abc.heif',
    );
    await store.upsert(localId: 'photo', contentHash: 'p', platform: 'ios');
    await store.updateDerivative(
      'photo',
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'photos-vault/originals/20210912023824_abc.heic',
      ),
    );
    await listed(['photos-vault/originals/20210912023824_abc.heic']);

    final scan = await fixer().scan();

    expect(scan.lost, isEmpty);
    expect((await store.listAll()).map((r) => r.localId), ['photo']);
  });

  test('cloud-only with no thumbnail, or a thumbnail file gone, is '
      'flagged; one with its picture is not', () async {
    final kept = File('${tempDir.path}/kept.jpg')..writeAsBytesSync([1]);
    await cloudOnly('bare', key: 'photos-vault/originals/bare.mov');
    await cloudOnly(
      'stale',
      key: 'photos-vault/originals/stale.mov',
      thumbnail: '${tempDir.path}/gone.jpg',
    );
    await cloudOnly(
      'fine',
      key: 'photos-vault/originals/fine.mov',
      thumbnail: kept.path,
    );
    await listed([
      'photos-vault/originals/bare.mov',
      'photos-vault/originals/stale.mov',
      'photos-vault/originals/fine.mov',
    ]);

    final found = await fixer().scan();

    expect([
      for (final f in found.noThumbnail) f.asset!.localId,
    ], unorderedEquals(['bare', 'stale']));
    expect(found.noThumbnail.first.solutions, [FlagSolution.makeThumbnail]);
    expect(found.noThumbnail.first.bytes, 4096);
    expect(found.noThumbnail.first.name, 'bare.mov');
    expect(found.lost, isEmpty);
  });

  test('Make Thumbnails makes a video frame without the download, and the '
      'record points at it', () async {
    await cloudOnly(
      'clip',
      key: 'photos-vault/originals/clip.mov',
      video: true,
    );
    await listed(['photos-vault/originals/clip.mov']);
    final frames = <Map<String, Object>>[];
    final asked = <String>[];
    final records = fixer(
      asked: asked,
      frame: (args) async {
        frames.add(args);
        File(args['output']! as String).writeAsBytesSync([7]);
        return true;
      },
    );
    final flags = (await records.scan()).noThumbnail;
    final q = queue(records)..enqueue(flags, FlagSolution.makeThumbnail);
    await drained(q);

    expect(q.isResolved(flags.single), isTrue);
    expect(frames.single['url'], contains('photos-vault/originals/clip.mov'));
    expect(frames.single.containsKey('bytes'), isFalse);
    expect(asked.where((p) => p.contains('/originals/')), isEmpty);
    final path = (await store.getByLocalId('clip'))!.thumbnailPath;
    expect(path, frames.single['output']);
    expect((await records.scan()).noThumbnail, isEmpty);
  });

  test('a photo is made from its first bytes only', () async {
    await cloudOnly('pic', key: 'photos-vault/originals/pic.jpg');
    await listed(['photos-vault/originals/pic.jpg']);
    final records = RecordFixer(
      store: store,
      thumbnail: OriginalRestore(
        targetsStore: targets,
        recordStore: store,
        directory: () async => tempDir,
        get: (url) async => url.path.contains('/originals/')
            ? http.Response.bytes([1, 2, 3], 206)
            : http.Response('', 404),
        frame: (args) async => args['bytes'] is List<int>,
      ).restoreThumbnail,
      inPhotos: (_) async => false,
      remove: (_) async => false,
    );

    final result = await records.makeThumbnail(
      (await store.getByLocalId('pic'))!,
    );

    expect(result.ok, isTrue);
    expect((await store.getByLocalId('pic'))!.thumbnailPath, isNotNull);
  });

  test('a thumbnail nothing can make fails with its reason', () async {
    await cloudOnly(
      'clip',
      key: 'photos-vault/originals/clip.mov',
      video: true,
    );
    await listed(['photos-vault/originals/clip.mov']);
    final records = fixer();
    final flags = (await records.scan()).noThumbnail;
    final q = queue(records)..enqueue(flags, FlagSolution.makeThumbnail);
    await drained(q);

    expect(q.jobs[flags.single.id]?.state, FixJobState.failed);
    expect(q.jobs[flags.single.id]?.detail, 'no bucket had it');
  });

  test('only in a removed bucket: lost, and Photos decides the fix', () async {
    await cloudOnly(
      'inPhotos',
      key: 'photos-vault2/originals/a.jpg',
      libraryId: 'lib-a',
    );
    await cloudOnly(
      'nowhere',
      key: 'photos-vault2/originals/b.jpg',
      libraryId: 'lib-b',
    );
    // The same file under the bucket set up now is not lost.
    await cloudOnly('moved', key: 'photos-vault2/originals/c.jpg');
    await listed(['photos-vault/originals/c.jpg']);

    final found = await fixer(inPhotos: {'inPhotos'}).scan();
    final byId = {for (final f in found.lost) f.asset!.localId: f};

    expect(byId.keys, unorderedEquals(['inPhotos', 'nowhere']));
    expect(byId['inPhotos']!.solutions, [FlagSolution.getFromPhotos]);
    expect(byId['nowhere']!.solutions, [FlagSolution.removeFromLibrary]);
    expect(byId['inPhotos']!.problems, {FlagProblem.missingFromBucket});
    expect([for (final f in found.noThumbnail) f.asset!.localId], ['moved']);
  });

  test('a listing cut short never makes a photo lost: the bucket is asked, '
      'and what it has is linked back', () async {
    await cloudOnly('there', key: 'photos-vault/originals/x.heif');
    await cloudOnly('gone', key: 'photos-vault/originals/y.heif');
    await listed(['photos-vault/originals/unrelated.jpg']);

    final found = await fixer(inBucket: {'x'}).scan();

    expect(found.lost.map((f) => f.asset!.localId), ['gone']);
    expect(
      (await store.getByLocalId('there'))!
          .stateOf(DerivativeKind.original)
          .destinationKey,
      'photos-vault/originals/x.heic',
    );
  });

  test('a bucket that does not answer makes nothing lost, and Remove from '
      'Library refuses', () async {
    await cloudOnly('a', key: 'photos-vault/originals/a.jpg');
    await listed(['photos-vault/originals/unrelated.jpg']);
    var removed = 0;
    final f = RecordFixer(
      store: store,
      thumbnail: (_) async => null,
      inPhotos: (_) async => false,
      liveOriginal: (_) async => throw StateError('offline'),
      remove: (_) async {
        removed++;
        return true;
      },
    );

    expect((await f.scan()).lost, isEmpty);
    expect(
      (await f.removeFromLibrary((await store.getByLocalId('a'))!)).ok,
      isFalse,
    );
    expect(removed, 0);
  });

  test('Get from Photos ends cloud-only and owes a backup; Remove drops the '
      'record', () async {
    await cloudOnly(
      'inPhotos',
      key: 'photos-vault2/originals/a.jpg',
      libraryId: 'lib-a',
    );
    await cloudOnly('nowhere', key: 'photos-vault2/originals/b.jpg');
    await listed(['photos-vault/originals/other.jpg']);
    final records = fixer(inPhotos: {'inPhotos'});
    final lost = (await records.scan()).lost;
    final q = queue(records)
      ..enqueue(
        lost.where((f) => f.solutions.contains(FlagSolution.getFromPhotos)),
        FlagSolution.getFromPhotos,
      );
    await drained(q);
    q.enqueue(
      lost.where((f) => f.solutions.contains(FlagSolution.removeFromLibrary)),
      FlagSolution.removeFromLibrary,
    );
    await drained(q);

    final back = (await store.getByLocalId('inPhotos'))!;
    expect(back.localDeleted, isFalse);
    expect(back.stateOf(DerivativeKind.original).status, UploadStatus.pending);
    expect(await store.getByLocalId('nowhere'), isNull);
    expect(lost.every(q.isResolved), isTrue);
    expect((await records.scan()).lost, isEmpty);
  });

  test('Get from Photos refuses once Photos has let go', () async {
    await cloudOnly(
      'gone',
      key: 'photos-vault2/originals/a.jpg',
      libraryId: 'lib-a',
    );
    final result = await fixer().getFromPhotos(
      (await store.getByLocalId('gone'))!,
    );
    expect(result.ok, isFalse);
    expect((await store.getByLocalId('gone'))!.localDeleted, isTrue);
  });

  test('a waiting record fix is filed and resumed', () async {
    await cloudOnly(
      'clip',
      key: 'photos-vault/originals/clip.mov',
      video: true,
    );
    await listed(['photos-vault/originals/clip.mov']);
    final flag = (await fixer().scan()).noThumbnail.single;
    await store.setAppState(
      'fix_queue_v1',
      jsonEncode([
        {
          'id': flag.id,
          'solution': 'makeThumbnail',
          'localId': 'clip',
          'problem': 'noThumbnail',
          'bytes': 4096,
          'name': 'clip.mov',
        },
      ]),
    );
    final q = queue(
      fixer(
        frame: (args) async {
          File(args['output']! as String).writeAsBytesSync([7]);
          return true;
        },
      ),
    );
    await q.resume();
    await drained(q);

    expect(q.isResolved(flag), isTrue);
    expect((await store.getByLocalId('clip'))!.thumbnailPath, isNotNull);
  });
}

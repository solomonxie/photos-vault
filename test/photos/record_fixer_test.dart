import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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

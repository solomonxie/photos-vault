import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_listing.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/backup_verifier.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_asset_record_store.dart';

Future<BackupTargetsStore> _targets({int count = 1}) async {
  final store = BackupTargetsStore(store: FakeSecureStore());
  for (var i = 0; i < count; i++) {
    await store.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'bucket$i',
      prefix: 'photos/',
    );
  }
  return store;
}

Future<AssetRecord> _uploaded(
  FakeAssetRecordStore store, {
  String localId = 'photo:1',
  String key = 'photos/originals/photo_1.heic',
  bool isLivePhoto = false,
  String? motionKey,
  String? backedUpHash,
}) async {
  await store.upsert(
    localId: localId,
    contentHash: localId,
    platform: 'ios',
    isLivePhoto: isLivePhoto,
  );
  await store.updateDerivative(
    localId,
    DerivativeKind.original,
    DerivativeState(
      status: UploadStatus.uploaded,
      destinationKey: key,
      backedUpHash: backedUpHash,
    ),
  );
  if (motionKey != null) {
    await store.updateDerivative(
      localId,
      DerivativeKind.livePhoto,
      DerivativeState(status: UploadStatus.uploaded, destinationKey: motionKey),
    );
  }
  return (await store.getByLocalId(localId))!;
}

S3ListingResult _listing(List<String> keys) => S3ListingResult(
  S3ListingOutcome.ok,
  page: S3ListingPage(
    folders: const [],
    objects: [
      for (final key in keys)
        S3Object(key: key, size: 10, lastModified: DateTime(2026)),
    ],
  ),
);

void main() {
  group('proveOriginal', () {
    test("an edited photo is proven only with its edit there (PW3b)", () async {
      final store = FakeAssetRecordStore();
      await _uploaded(store);
      await store.setHasEdit('photo:1', true);
      final asked = <String>[];
      final targets = await _targets();
      BackupVerifier verifier(int editStatus) => BackupVerifier(
        targetsStore: targets,
        recordStore: store,
        head: (url) async {
          asked.add(url.path);
          return http.Response(
            '',
            url.path.contains('/edited/') ? editStatus : 200,
          );
        },
      );

      var record = (await store.getByLocalId('photo:1'))!;
      expect(
        await verifier(200).proveOriginal(record),
        CopyProof.missing,
        reason: 'no edit recorded: the phone has the only copy of the look',
      );
      await store.updateDerivative(
        'photo:1',
        DerivativeKind.edited,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'photos/edited/photo_1.heic',
        ),
      );
      record = (await store.getByLocalId('photo:1'))!;
      expect(await verifier(404).proveOriginal(record), CopyProof.missing);
      expect(await verifier(200).proveOriginal(record), CopyProof.present);
      expect(asked.last, '/photos/edited/photo_1.heic');
    });

    test('a bucket that answers 200 is proof', () async {
      final store = FakeAssetRecordStore();
      final record = await _uploaded(store);
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        head: (_) async => http.Response('', 200),
      );

      expect(await verifier.proveOriginal(record), CopyProof.present);
    });

    test('only a 404 means the bucket hasn\'t got it', () async {
      final store = FakeAssetRecordStore();
      final record = await _uploaded(store);

      expect(
        await BackupVerifier(
          targetsStore: await _targets(),
          recordStore: store,
          head: (_) async => http.Response('', 404),
        ).proveOriginal(record),
        CopyProof.missing,
      );
      // 403 is a bucket without HeadObject permission, not an absent
      // object — reporting that as a loss would be a lie that costs trust.
      expect(
        await BackupVerifier(
          targetsStore: await _targets(),
          recordStore: store,
          head: (_) async => http.Response('', 403),
        ).proveOriginal(record),
        CopyProof.unreachable,
      );
    });

    test('one bucket out of two is enough', () async {
      final store = FakeAssetRecordStore();
      final record = await _uploaded(store);
      var call = 0;
      final verifier = BackupVerifier(
        targetsStore: await _targets(count: 2),
        recordStore: store,
        head: (_) async => http.Response('', call++ == 0 ? 404 : 200),
      );

      expect(await verifier.proveOriginal(record), CopyProof.present);
    });

    test('no target configured is unreachable, never missing', () async {
      final store = FakeAssetRecordStore();
      final record = await _uploaded(store);
      final verifier = BackupVerifier(
        targetsStore: BackupTargetsStore(store: FakeSecureStore()),
        recordStore: store,
        head: (_) async => http.Response('', 200),
      );

      expect(await verifier.proveOriginal(record), CopyProof.unreachable);
    });

    test('a Live Photo needs both halves', () async {
      final store = FakeAssetRecordStore();
      final record = await _uploaded(
        store,
        isLivePhoto: true,
        motionKey: 'photos/originals/photo_1.mov',
      );
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        head: (url) async =>
            http.Response('', url.path.endsWith('.mov') ? 404 : 200),
      );

      // The still is there and the motion isn't, which is a missing copy of
      // this photo — a Live Photo backed up as a still is a silent still.
      expect(await verifier.proveOriginal(record), CopyProof.missing);
    });
  });

  group('reconcile', () {
    test('names what the bucket has not got, and re-queues it', () async {
      final store = FakeAssetRecordStore();
      await _uploaded(store, localId: 'photo:here', key: 'photos/originals/a');
      await _uploaded(store, localId: 'photo:gone', key: 'photos/originals/b');
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        list: ({required target, prefix = '', continuationToken}) async =>
            _listing(['photos/originals/a']),
      );

      final report = await verifier.reconcile();

      expect(report.reachedBucket, isTrue);
      expect(report.expected, 2);
      expect(report.present, 1);
      expect(report.missingLocalIds, ['photo:gone']);
      expect(report.isClean, isFalse);

      expect(await verifier.requeueMissing(report), 1);
      final requeued = (await store.getByLocalId('photo:gone'))!;
      expect(
        requeued.stateOf(DerivativeKind.original).status,
        UploadStatus.pending,
      );
      // The one that is really there keeps saying so.
      final kept = (await store.getByLocalId('photo:here'))!;
      expect(
        kept.stateOf(DerivativeKind.original).status,
        UploadStatus.uploaded,
      );
    });

    test(
      'hidden and locked photos are in no count, nor unreferenced',
      () async {
        final store = FakeAssetRecordStore();
        await _uploaded(
          store,
          localId: 'photo:open',
          key: 'photos/originals/a',
        );
        await _uploaded(store, localId: 'photo:hid', key: 'photos/originals/h');
        await _uploaded(
          store,
          localId: 'photo:lock',
          key: 'photos/originals/l',
        );
        await _uploaded(
          store,
          localId: 'photo:gone',
          key: 'photos/originals/g',
        );
        await store.setHidden('photo:hid', true);
        await store.setPasscodeHash('photo:lock', 'tag');
        await store.setHidden('photo:gone', true);
        final verifier = BackupVerifier(
          targetsStore: await _targets(),
          recordStore: store,
          list: ({required target, prefix = '', continuationToken}) async =>
              _listing([
                'photos/originals/a',
                'photos/originals/h',
                'photos/originals/l',
              ]),
        );

        final report = await verifier.reconcile();

        expect(report.expected, 1);
        expect(report.present, 1);
        expect(report.missingLocalIds, isEmpty);
        expect(report.unreferencedKeys, isEmpty);
        expect(report.isClean, isTrue);

        // The unseen daily repair still looks after them.
        final all = await verifier.reconcile(includeHidden: true);
        expect(all.missingLocalIds, ['photo:gone']);
      },
    );

    test('a Live Photo missing its motion half is missing', () async {
      final store = FakeAssetRecordStore();
      await _uploaded(
        store,
        localId: 'photo:live',
        key: 'photos/originals/live.heic',
        isLivePhoto: true,
        motionKey: 'photos/originals/live.mov',
      );
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        list: ({required target, prefix = '', continuationToken}) async =>
            _listing(['photos/originals/live.heic']),
      );

      final report = await verifier.reconcile();

      expect(report.missingLocalIds, ['photo:live']);
      expect(await verifier.requeueMissing(report), 1);
      final requeued = (await store.getByLocalId('photo:live'))!;
      expect(
        requeued.stateOf(DerivativeKind.livePhoto).status,
        UploadStatus.pending,
      );
    });

    test('a present motion half is neither missing nor an orphan', () async {
      final store = FakeAssetRecordStore();
      await _uploaded(
        store,
        key: 'photos/originals/live.heic',
        isLivePhoto: true,
        motionKey: 'photos/originals/live.mov',
      );
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        list: ({required target, prefix = '', continuationToken}) async =>
            _listing([
              'photos/originals/live.heic',
              'photos/originals/live.mov',
            ]),
      );

      final report = await verifier.reconcile();

      expect(report.isClean, isTrue);
      expect(report.unreferencedKeys, isEmpty);
    });

    test('an object no record claims is reported, never deleted', () async {
      final store = FakeAssetRecordStore();
      await _uploaded(store, key: 'photos/originals/a');
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        list: ({required target, prefix = '', continuationToken}) async =>
            _listing(['photos/originals/a', 'photos/originals/orphan']),
      );

      final report = await verifier.reconcile();

      expect(report.unreferencedKeys, ['photos/originals/orphan']);
      expect(report.isClean, isTrue);
    });

    test('a copy only in a removed bucket is missing', () async {
      final store = FakeAssetRecordStore();
      await _uploaded(store, key: 'old/originals/a');
      await store.recordUpload(
        localId: 'photo:1',
        kind: DerivativeKind.original,
        targetId: 'removed-target',
        destinationKey: 'old/originals/a',
      );
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        list: ({required target, prefix = '', continuationToken}) async =>
            _listing(['photos/originals/other']),
      );

      final report = await verifier.reconcile();

      expect(report.missingLocalIds, ['photo:1']);
      expect(await verifier.requeueMissing(report), 1);
    });

    test('the daily check requeues what the bucket lost, once a day', () async {
      final store = FakeAssetRecordStore();
      await _uploaded(store, key: 'photos/originals/a');
      var asked = 0;
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        list: ({required target, prefix = '', continuationToken}) async {
          asked++;
          return _listing(['photos/originals/other']);
        },
      );

      expect(await verifier.repairIfDue(), 1);
      expect(
        (await store.getByLocalId('photo:1'))!
            .stateOf(DerivativeKind.original)
            .status,
        UploadStatus.pending,
      );
      final listings = asked;
      expect(await verifier.repairIfDue(), 0);
      expect(asked, listings, reason: 'not due again the same day');
    });

    test('an unreachable holder is not called missing', () async {
      final store = FakeAssetRecordStore();
      await _uploaded(store, key: 'photos/originals/a');
      final targets = await _targets(count: 2);
      final holder = (await targets.loadAll()).first;
      await store.recordUpload(
        localId: 'photo:1',
        kind: DerivativeKind.original,
        targetId: holder.id,
        destinationKey: 'photos/originals/a',
      );
      final verifier = BackupVerifier(
        targetsStore: targets,
        recordStore: store,
        list: ({required target, prefix = '', continuationToken}) async =>
            target.id == holder.id
            ? const S3ListingResult(S3ListingOutcome.networkError)
            : _listing(['photos/originals/other']),
      );

      expect((await verifier.reconcile()).missingLocalIds, isEmpty);
    });

    test('an unreachable bucket reports nothing rather than zero', () async {
      final store = FakeAssetRecordStore();
      await _uploaded(store);
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        list: ({required target, prefix = '', continuationToken}) async =>
            const S3ListingResult(S3ListingOutcome.networkError),
      );

      final report = await verifier.reconcile();

      expect(report.reachedBucket, isFalse);
      expect(report.isClean, isFalse);
      // Nothing was learned, so nothing is marked as verified either.
      expect(await verifier.lastVerifiedAt(), isNull);
    });

    test('pages past the thousand-key listing limit', () async {
      final store = FakeAssetRecordStore();
      await _uploaded(store, localId: 'photo:1', key: 'photos/originals/a');
      await _uploaded(store, localId: 'photo:2', key: 'photos/originals/b');
      var page = 0;
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        list: ({required target, prefix = '', continuationToken}) async {
          if (!prefix.endsWith('originals/')) {
            return const S3ListingResult(
              S3ListingOutcome.ok,
              page: S3ListingPage(folders: [], objects: []),
            );
          }
          page++;
          return S3ListingResult(
            S3ListingOutcome.ok,
            page: S3ListingPage(
              folders: const [],
              objects: [
                S3Object(
                  key: page == 1 ? 'photos/originals/a' : 'photos/originals/b',
                  size: 10,
                  lastModified: DateTime(2026),
                ),
              ],
              nextToken: page == 1 ? 'more' : null,
            ),
          );
        },
      );

      final report = await verifier.reconcile();

      expect(page, 2);
      expect(report.missingLocalIds, isEmpty);
    });
  });

  group('testRestore', () {
    test('downloads photos back and checks the bytes', () async {
      final bytes = utf8.encode('the original bytes');
      final hash = sha256.convert(bytes).toString();
      final store = FakeAssetRecordStore();
      await _uploaded(store, backedUpHash: hash);
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        get: (_) async => http.Response.bytes(bytes, 200),
      );

      final report = await verifier.testRestore();

      expect(report.attempted, 1);
      expect(report.verified, 1);
      expect(report.allVerified, isTrue);
      expect(report.photos.single.byteIdentical, isTrue);
      expect(await verifier.lastVerifiedAt(), isNotNull);
    });

    test('bytes that came back wrong are a failure', () async {
      final store = FakeAssetRecordStore();
      await _uploaded(store, backedUpHash: 'not-this');
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        get: (_) async =>
            http.Response.bytes(utf8.encode('something else'), 200),
      );

      final report = await verifier.testRestore();

      expect(report.photos.single.byteIdentical, isFalse);
      expect(report.allVerified, isFalse);
    });

    test('an optimized upload is not expected to match', () async {
      // The object in the bucket is a WebP re-encode; `backedUpHash` is the
      // hash of the file on the phone. Calling that a mismatch would fail
      // every drill on the default format.
      final store = FakeAssetRecordStore();
      await _uploaded(
        store,
        key: 'photos/originals/photo_1.webp',
        backedUpHash: 'the-heic-hash',
      );
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        get: (_) async => http.Response.bytes(utf8.encode('webp bytes'), 200),
      );

      final report = await verifier.testRestore();

      expect(report.photos.single.byteIdentical, isNull);
      expect(report.allVerified, isTrue);
    });

    test('a download that fails is not a pass', () async {
      final store = FakeAssetRecordStore();
      await _uploaded(store);
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        get: (_) async => http.Response('', 500),
      );

      final report = await verifier.testRestore();

      expect(report.photos.single.downloadedBytes, 0);
      expect(report.allVerified, isFalse);
    });

    test('nothing backed up means nothing to try', () async {
      final store = FakeAssetRecordStore();
      await store.upsert(
        localId: 'photo:fresh',
        contentHash: 'f',
        platform: 'ios',
      );
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        get: (_) async => http.Response('', 200),
      );

      final report = await verifier.testRestore();

      expect(report.attempted, 0);
      expect(report.allVerified, isFalse);
      expect(await verifier.lastVerifiedAt(), isNull);
    });
  });

  group('spotCheck', () {
    test('never-checked cloud-only photos first, then the longest ago; '
        'only whole backups, and nothing written but the few rows', () async {
      final store = FakeAssetRecordStore();
      Future<void> cloudOnly(String id, int day, {bool live = false}) async {
        await store.upsert(
          localId: id,
          contentHash: id,
          platform: 'ios',
          isLivePhoto: live,
          createdAt: DateTime(2026, 1, day),
        );
        await store.updateDerivative(
          id,
          DerivativeKind.original,
          DerivativeState(
            status: UploadStatus.uploaded,
            destinationKey: 'photos/originals/$id.heic',
          ),
        );
        await store.setLocalDeleted(id, true);
      }

      for (final (id, day) in [('a', 1), ('b', 2), ('c', 3)]) {
        await cloudOnly(id, day);
      }
      // Its motion half not up: no whole backup to ask about.
      await cloudOnly('half', 0, live: true);
      await store.upsert(
        localId: 'hidden',
        contentHash: 'hidden',
        platform: 'ios',
        passcodeHash: 'x',
      );
      final asked = <String>[];
      var status = 200;
      final verifier = BackupVerifier(
        targetsStore: await _targets(),
        recordStore: store,
        head: (uri) async {
          asked.add(uri.path.split('/').last);
          return http.Response('', status);
        },
      );
      Future<List<String>> round() async {
        asked.clear();
        await verifier.spotCheck(limit: 2, every: Duration.zero);
        return [...asked];
      }

      expect(await round(), ['a.heic', 'b.heic']);
      expect(await round(), ['c.heic', 'a.heic']);
      expect(store.spotChecked.keys, {'a', 'b', 'c'});

      store.spotChecked.addAll({'a': 300, 'b': 100, 'c': 200});
      status = 500;
      expect(await round(), ['b.heic', 'c.heic']);
      status = 200;
      expect(await round(), [
        'b.heic',
        'c.heic',
      ], reason: 'no answer is not a check');
      expect(store.spotChecked['b'], greaterThan(300));
      expect(store.spotChecked['a'], 300);
      expect(await store.getAppState('spot_checked_at'), isNull);
    });
  });
}

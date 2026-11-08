import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/bucket_object.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/vault/album_index.dart';
import 'package:photos_vault/vault/bucket.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/filed_photos.dart';
import 'package:photos_vault/vault/hidden_leftovers.dart';
import 'package:photos_vault/vault/hidden_notes.dart';
import 'package:photos_vault/vault/hidden_transition.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/object_key.dart';
import 'package:photos_vault/vault/owner_folder.dart';
import 'package:photos_vault/vault/passcode_tags.dart';
import 'package:photos_vault/vault/retired_carriers.dart';
import 'package:photos_vault/vault/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/memory_bucket.dart';
import 'carrier_fixtures.dart';

class _NoExclusion extends BackupExclusion {
  const _NoExclusion();

  @override
  Future<bool> exclude(String path) async => true;
}

void main() {
  setUpAll(sqfliteFfiInit);

  late FakeAssetRecordStore records;
  late PersonStore people;
  late VaultKeys keys;
  late Directory dir;

  Future<String> tagOf(String code) => PasscodeTags(
    records: records,
    people: people,
    vaultKeys: keys,
  ).tagFor(code);

  Future<AlbumKeys> keysOf(String code) async =>
      (await keys.activeAlbumKeys(code))!;

  Future<void> photo(String id, String tag) async {
    final file = File('${dir.path}/$id.jpg')..writeAsBytesSync([1, 2, 3]);
    await records.upsert(
      localId: id,
      contentHash: id,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: file.path,
    );
    await records.setPasscodeHash(id, tag);
    await records.updateDerivative(
      id,
      DerivativeKind.original,
      DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'p/originals/$id.jpg',
      ),
    );
  }

  HiddenTransition transition() => HiddenTransition(
    store: records,
    loadTargets: () async => const [],
    pendingDeletes: PendingDeletes(store: records, ops: MemoryBucket()),
    analysisStore: FakeAiAnalysisStore(),
    thumbnails: ThumbnailCache(store: records),
  );

  OwnerFolder folder({bool bucketHolds = false}) => OwnerFolder(
    store: records,
    people: people,
    vaultKeys: keys,
    transition: transition(),
    bucketHolds: (_, _) async => bucketHolds,
  );

  Future<int> queuedDeletes() async => [
    for (final q in const ['pending', 'deferred', 'held'])
      ...await records.queuedDeletes(q),
  ].length;

  setUp(() async {
    records = FakeAssetRecordStore();
    people = PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    keys = VaultKeys(store: FakeSecureStore(), derive: deriveOnThisIsolate);
    await keys.add('a good long passphrase');
    dir = Directory.systemTemp.createTempSync('pv_owner_');
  });

  tearDown(() async {
    await people.close();
    dir.deleteSync(recursive: true);
  });

  group('the bare digits move into the owner folder on unlock', () {
    test('current and legacy tags, re-encrypted, nothing deleted', () async {
      final plain = await tagOf('1234');
      await photo('current', plain);
      await photo('legacy', hashPasscode('1234'));
      final oldKeys = await keysOf('1234');
      final note = await HiddenNotes(
        store: records,
        keys: oldKeys,
      ).save('flight AS 841');

      final left = await folder().adoptPlain('me', '1234');

      final ownerTag = await tagOf(personAlbumCode('me', '1234'));
      final ownerKeys = await keysOf(personAlbumCode('me', '1234'));
      expect(left, isEmpty);
      expect(
        (await records.forPasscodeHash(ownerTag)).map((r) => r.localId),
        unorderedEquals(['current', 'legacy']),
      );
      expect(await records.forPasscodeHash(plain), isEmpty);
      expect(await records.forPasscodeHash(hashPasscode('1234')), isEmpty);
      // Uploads reset: the backup sends them again under the owner's key.
      for (final r in await records.forPasscodeHash(ownerTag)) {
        expect(r.stateOf(DerivativeKind.original).status, UploadStatus.pending);
      }
      expect(await queuedDeletes(), 0);
      // The note is sealed again under the owner's key, same id.
      final moved = await HiddenNotes(store: records, keys: ownerKeys).list();
      expect(moved.single.id, note.id);
      expect(moved.single.text, 'flight AS 841');
      expect(await HiddenNotes(store: records, keys: oldKeys).list(), isEmpty);
      // On the ring under the owner's tag, so uploads resume.
      expect(keys.ringKeysFor(ownerTag), isNotNull);
      expect(await keys.ringTags(), contains(ownerTag));
    });

    test('sealed profile sets are sealed again under the owner key', () async {
      final plain = await tagOf('1234');
      final mia = await people.create(name: 'Mia');
      await people.saveDetail(
        mia.id,
        const PersonDetail(bio: 'secret'),
        scope: PersonScope.sealed(plain, await keysOf('1234')),
      );

      await folder().adoptPlain('me', '1234');

      final ownerTag = await tagOf(personAlbumCode('me', '1234'));
      expect(await people.namespaces(), {ownerTag});
      final detail = await people.detailFor(
        mia.id,
        passcodeHash: ownerTag,
        keys: await keysOf(personAlbumCode('me', '1234')),
      );
      expect(detail.bio, 'secret');
    });

    test('one that cannot move stays, and the bare digits open too', () async {
      final plain = await tagOf('1234');
      await photo('cloudOnly', plain);
      await records.setLocalDeleted('cloudOnly', true);

      expect(await folder().adoptPlain('me', '1234'), ['1234']);
      expect(await records.forPasscodeHash(plain), hasLength(1));
    });

    test('carriers only the bucket has keep the bare digits open', () async {
      expect(await folder(bucketHolds: true).adoptPlain('me', '1234'), [
        '1234',
      ]);
    });

    test('other digits are left where they are', () async {
      final plain = await tagOf('5678');
      await photo('other', plain);

      await folder().adoptPlain('me', '1234');

      expect(await records.forPasscodeHash(plain), hasLength(1));
    });

    test('changing the owner leaves folders with who they were made '
        'for', () async {
      await photo('a', await tagOf('1234'));
      await folder().adoptPlain('ann', '1234');
      final annTag = await tagOf(personAlbumCode('ann', '1234'));

      await folder().adoptPlain('ben', '1234');

      expect(await records.forPasscodeHash(annTag), hasLength(1));
      expect(
        await records.forPasscodeHash(
          await tagOf(personAlbumCode('ben', '1234')),
        ),
        isEmpty,
      );
    });
  });

  group('what a left-behind folder still really holds', () {
    BucketObject carrierObject(String fileName) => BucketObject(
      targetId: 't',
      key: 'p/originals/$fileName',
      size: 1,
      lastModified: DateTime(2026),
    );

    HiddenLeftovers leftovers() =>
        HiddenLeftovers(store: records, readIndex: () async => null);

    test('old copies of moved photos do not count; a carrier of its own '
        'does, once for both halves', () async {
      final plain = await tagOf('1234');
      await photo('a', plain);
      await photo('b', plain);
      final old = await keysOf('1234');
      final moving = [
        for (final id in ['a', 'b']) (await records.getByLocalId(id))!,
      ];
      await folder().adoptPlain('me', '1234', lookInBucket: false);
      // Moves never delete: the old carriers stay in the listing.
      final stale = [
        for (final r in moving)
          carrierObject(vaultCarrierKey(r, old.carrier).split('/').last),
      ];
      await records.replaceBucketObjects('t', stale);

      expect(await leftovers().count(plain, old), 0);
      expect(
        await folder(bucketHolds: false).adoptPlain('me', '1234'),
        isEmpty,
      );
      expect(
        await OwnerFolder(
          store: records,
          people: people,
          vaultKeys: keys,
          transition: transition(),
        ).adoptPlain('me', '1234'),
        isEmpty,
      );

      final own = hiddenBaseNameFor(old.carrier, 'from another phone');
      await records.replaceBucketObjects('t', [
        ...stale,
        carrierObject('$own.jpg'),
        carrierObject('$own.mov'),
      ]);
      expect(await leftovers().count(plain, old), 1);
    });

    test('an old copy named in another time zone is still the moved '
        "photo's, and does not count", () async {
      final plain = await tagOf('1234');
      await photo('a', plain);
      final old = await keysOf('1234');
      final moving = (await records.getByLocalId('a'))!;
      await folder().adoptPlain('me', '1234', lookInBucket: false);
      final name = vaultCarrierKey(moving, old.carrier).split('/').last;
      // The same carrier, its stamp an hour off: written on a phone in
      // another zone.
      final hour = int.parse(name.substring(8, 10));
      final shifted =
          '${name.substring(0, 8)}'
          '${((hour + 1) % 24).toString().padLeft(2, '0')}'
          '${name.substring(10)}';
      expect(shifted, isNot(name));
      await records.replaceBucketObjects('t', [carrierObject(shifted)]);

      expect(await leftovers().count(plain, old), 0);
      expect(
        await supersededCarrierKeys(records, plain, old),
        contains(carrierIdentity('originals/$shifted')),
      );
    });

    test('a retired carrier does not count', () async {
      final plain = await tagOf('1234');
      final old = await keysOf('1234');
      final own = hiddenBaseNameFor(old.carrier, 'lost');
      await records.replaceBucketObjects('t', [carrierObject('$own.jpg')]);
      expect(await leftovers().count(plain, old), 1);

      await RetiredCarriers(records).add(['originals/$own.jpg']);

      expect(await leftovers().count(plain, old), 0);
    });

    test('rows still under its tag count', () async {
      final plain = await tagOf('1234');
      await photo('stuck', plain);

      expect(await leftovers().count(plain, await keysOf('1234')), 1);
      expect(await leftovers().count(plain, null), 1);
    });
  });

  group('move to person', () {
    test('a subset goes to their folder under the same digits', () async {
      final fromCode = personAlbumCode('me', '1234');
      final fromTag = await tagOf(fromCode);
      final from = (await keys.unlockAlbum(fromCode, fromTag))!;
      await photo('go', fromTag);
      await photo('stay', fromTag);
      await HiddenNotes(store: records, keys: from).save('album note');
      final moving = (await records.getByLocalId('go'))!;

      final result = await moveToPersonFolder(
        store: records,
        vaultKeys: keys,
        transition: transition(),
        from: from,
        fromTag: fromTag,
        personId: 'kim',
        digits: '1234',
        localIds: ['go'],
        people: people,
      );

      final kimTag = await tagOf(personAlbumCode('kim', '1234'));
      expect(result.moved, 1);
      expect((await records.forPasscodeHash(kimTag)).map((r) => r.localId), [
        'go',
      ]);
      expect((await records.forPasscodeHash(fromTag)).map((r) => r.localId), [
        'stay',
      ]);
      final moved = (await records.getByLocalId('go'))!;
      expect(
        moved.stateOf(DerivativeKind.original).status,
        UploadStatus.pending,
      );
      // Nothing queued for deletion; their key is on the ring.
      expect(await queuedDeletes(), 0);
      expect(keys.ringKeysFor(kimTag), isNotNull);
      expect(await keys.ringTags(), contains(kimTag));
      // Notes stay with the folder they were written in.
      expect(
        (await HiddenNotes(store: records, keys: from).list()).single.text,
        'album note',
      );
      // The source no longer shows its old carrier of the moved photo.
      expect(
        await supersededCarrierKeys(records, fromTag, from),
        contains(carrierIdentity(vaultCarrierKey(moving, from.carrier))),
      );
    });

    test('the same folder is refused', () async {
      final fromCode = personAlbumCode('kim', '1234');
      final fromTag = await tagOf(fromCode);
      await photo('a', fromTag);

      final result = await moveToPersonFolder(
        store: records,
        vaultKeys: keys,
        transition: transition(),
        from: await keys.unlockAlbum(fromCode, fromTag),
        fromTag: fromTag,
        personId: 'kim',
        digits: '1234',
        localIds: ['a'],
        people: people,
      );

      expect(result.sameFolder, isTrue);
      expect(await records.forPasscodeHash(fromTag), hasLength(1));
    });

    test('a failed move leaves the photo in the source', () async {
      final fromCode = personAlbumCode('me', '1234');
      final fromTag = await tagOf(fromCode);
      await photo('a', fromTag);
      records.crashAt = 'retract';

      final result = await moveToPersonFolder(
        store: records,
        vaultKeys: keys,
        transition: transition(),
        from: await keys.unlockAlbum(fromCode, fromTag),
        fromTag: fromTag,
        personId: 'kim',
        digits: '1234',
        localIds: ['a'],
        people: people,
      );

      expect(result.moved, 0);
      final record = (await records.getByLocalId('a'))!;
      expect(record.passcodeHash, fromTag);
      expect(
        record.stateOf(DerivativeKind.original).status,
        UploadStatus.uploaded,
      );
      // Not journaled for a later launch to finish.
      expect(await records.openTransitions(), isEmpty);
      expect(await queuedDeletes(), 0);
    });

    test('a photo only the bucket holds stays', () async {
      final fromCode = personAlbumCode('me', '1234');
      final fromTag = await tagOf(fromCode);
      await photo('a', fromTag);
      await records.setLocalDeleted('a', true);

      final result = await moveToPersonFolder(
        store: records,
        vaultKeys: keys,
        transition: transition(),
        from: await keys.unlockAlbum(fromCode, fromTag),
        fromTag: fromTag,
        personId: 'kim',
        digits: '1234',
        localIds: ['a'],
        people: people,
      );

      expect(result.moved, 0);
      expect((await records.getByLocalId('a'))!.passcodeHash, fromTag);
    });
  });

  group('photos only the bucket has are carried', () {
    final original = Uint8List.fromList(List.generate(5000, (i) => i % 251));
    final takenAt = DateTime(2026, 11, 1, 23, 35, 34);

    /// What the fake bucket holds, by object key; what it was asked.
    late Map<String, Uint8List> bucket;
    late int? answer;
    late List<String> writes;
    late Directory store;

    BucketObject listed(String fileName) => BucketObject(
      targetId: 't',
      key: 'p/originals/$fileName',
      size: 1,
      lastModified: DateTime(2026),
    );

    Uint8List carrierOf(AlbumKeys keys, String seed) => buildJpegCarrier(
      cipher: PlatformCipher(),
      keys: keys.carrier,
      masterSalt: keys.entry.salt,
      decoy: decoyJpeg(),
      thumbnail: Uint8List.fromList([1, 2, 3]),
      original: original,
      extension: 'heic',
      nonce: hiddenNonceFor(keys.carrier, seed),
      meta: CarrierMeta(
        takenAt: takenAt,
        width: 1170,
        height: 2532,
        isVideo: false,
      ),
    )!;

    /// A carrier under the bare digits that only the bucket has.
    Future<String> bucketOnly(String seed) async {
      final from = await keysOf('1234');
      final name = '${hiddenBaseNameFor(from.carrier, seed)}.jpg';
      bucket['originals/$name'] = carrierOf(from, seed);
      await records.replaceBucketObjects('t', [listed(name)]);
      return 'originals/$name';
    }

    Future<FiledPhotos> filed() async {
      final targets = BackupTargetsStore(store: FakeSecureStore());
      await targets.add(
        accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
        secretAccessKey: 'secret',
        region: 'us-east-1',
        bucket: 'b',
        prefix: 'p',
      );
      final vault = VaultStore(
        directory: () async => store,
        exclusion: const _NoExclusion(),
      );
      return FiledPhotos(
        records: records,
        store: vault,
        bucket: VaultBucket(
          targetsStore: targets,
          store: vault,
          put: (url, {body}) async {
            writes.add('$url');
            return http.Response('', 200);
          },
          download: (target, key, toPath) async {
            final bytes = bucket[key.substring('p/'.length)];
            if (answer != null) return (saved: false, status: answer);
            if (bytes == null) return (saved: false, status: 404);
            await File(toPath).writeAsBytes(bytes);
            return (saved: true, status: 200);
          },
        ),
        directory: () async => store,
        hashFile: (_) async => 'hash',
      );
    }

    HiddenLeftovers leftovers() =>
        HiddenLeftovers(store: records, readIndex: () async => null);

    setUp(() {
      bucket = {};
      answer = null;
      writes = [];
      store = Directory.systemTemp.createTempSync('pv_carry_');
    });
    tearDown(() => store.deleteSync(recursive: true));

    test('into the owner folder: a row there, sent again under its key; '
        'the old carrier stays and stops counting', () async {
      final plain = await tagOf('1234');
      final old = await keysOf('1234');
      final key = await bucketOnly('from an older build');
      expect(await leftovers().count(plain, old), 1);
      await folder().adoptPlain('me', '1234', lookInBucket: false);
      final ownerTag = await tagOf(personAlbumCode('me', '1234'));

      final result = await carryBucketOnly(
        store: records,
        from: old,
        fromTag: plain,
        toTag: ownerTag,
        filed: await filed(),
        leftovers: leftovers(),
      );

      expect(result, (moved: 1, stuck: 0));
      final row = (await records.forPasscodeHash(ownerTag)).single;
      expect(row.localId, FiledPhotos.carriedId(key));
      expect(row.createdAt, takenAt);
      expect((row.width, row.height), (1170, 2532));
      expect(File(row.sourcePath!).readAsBytesSync(), original);
      // Nothing uploaded yet: the backup encrypts it under the owner key.
      expect(row.stateOf(DerivativeKind.original).status, UploadStatus.pending);
      // The row is gone from the bare digits' count; nothing was written to
      // or deleted from a bucket.
      expect(await leftovers().count(plain, old), 0);
      expect(bucket.keys, [key]);
      expect(writes, isEmpty);
      expect(await queuedDeletes(), 0);

      // A second run finds nothing more to carry.
      expect(
        await carryBucketOnly(
          store: records,
          from: old,
          fromTag: plain,
          toTag: ownerTag,
          filed: await filed(),
          leftovers: leftovers(),
        ),
        (moved: 0, stuck: 0),
      );
      expect(await records.forPasscodeHash(ownerTag), hasLength(1));
    });

    test('a failed download leaves it in the source', () async {
      final plain = await tagOf('1234');
      final old = await keysOf('1234');
      await bucketOnly('unreachable');
      final ownerTag = await tagOf(personAlbumCode('me', '1234'));
      answer = 503;

      final result = await carryBucketOnly(
        store: records,
        from: old,
        fromTag: plain,
        toTag: ownerTag,
        filed: await filed(),
        leftovers: leftovers(),
      );

      expect(result, (moved: 0, stuck: 1));
      expect(await records.forPasscodeHash(ownerTag), isEmpty);
      expect(await leftovers().count(plain, old), 1);
      expect(await RetiredCarriers(records).all(), isEmpty);
    });

    test('one every bucket has lost no longer counts', () async {
      final plain = await tagOf('1234');
      final old = await keysOf('1234');
      final key = await bucketOnly('lost');
      bucket.remove(key);
      final ownerTag = await tagOf(personAlbumCode('me', '1234'));

      final result = await carryBucketOnly(
        store: records,
        from: old,
        fromTag: plain,
        toTag: ownerTag,
        filed: await filed(),
        leftovers: leftovers(),
      );

      expect(result, (moved: 1, stuck: 0));
      expect(await records.forPasscodeHash(ownerTag), isEmpty);
      expect(await leftovers().count(plain, old), 0);
    });

    test('Move to Person carries selected ones too', () async {
      final fromCode = personAlbumCode('me', '1234');
      final fromTag = await tagOf(fromCode);
      final from = (await keys.unlockAlbum(fromCode, fromTag))!;
      final name = '${hiddenBaseNameFor(from.carrier, 'cloud')}.jpg';
      bucket['originals/$name'] = carrierOf(from, 'cloud');
      await records.replaceBucketObjects('t', [listed(name)]);
      expect(await leftovers().count(fromTag, from), 1);

      final result = await moveToPersonFolder(
        store: records,
        vaultKeys: keys,
        transition: transition(),
        from: from,
        fromTag: fromTag,
        personId: 'kim',
        digits: '1234',
        localIds: const [],
        entries: [
          IndexEntry(
            objectKey: 'originals/$name',
            takenAt: DateTime(2020),
            width: 0,
            height: 0,
            isVideo: false,
            hasMotion: false,
          ),
        ],
        people: people,
        filed: await filed(),
      );

      final kimTag = await tagOf(personAlbumCode('kim', '1234'));
      expect(result.moved, 1);
      expect(await records.forPasscodeHash(kimTag), hasLength(1));
      expect(await leftovers().count(fromTag, from), 0);
      expect(writes, isEmpty);
      expect(keys.ringKeysFor(kimTag), isNotNull);
    });
  });
}

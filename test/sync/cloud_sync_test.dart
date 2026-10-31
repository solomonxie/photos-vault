import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/album.dart';
import 'package:photos_vault/storage/album_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/sync/apply.dart';
import 'package:photos_vault/sync/capture.dart';
import 'package:photos_vault/sync/cloud_sync.dart';
import 'package:photos_vault/sync/op.dart';
import 'package:photos_vault/sync/segment.dart';
import 'package:photos_vault/sync/sync_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../settings/fake_secure_store.dart';
import 'memory_log_bucket.dart';

class _Phone {
  _Phone(Directory dir, String name, MemoryLogBucket bucket, this.targets)
    : assets = AssetRecordStore(
        databaseFactory: databaseFactoryFfi,
        path: p.join(dir.path, '$name-photos.db'),
      ),
      albums = AlbumStore(
        databaseFactory: databaseFactoryFfi,
        path: p.join(dir.path, '$name-albums.db'),
      ),
      people = PersonStore(
        databaseFactory: databaseFactoryFfi,
        path: p.join(dir.path, '$name-people.db'),
      ),
      store = SyncStore(
        databaseFactory: databaseFactoryFfi,
        path: p.join(dir.path, '$name-sync.db'),
      ) {
    sync = CloudSync(
      assets: assets,
      albums: albums,
      people: people,
      targets: targets,
      store: store,
      bucketFor: (_) => bucket,
    );
  }

  final AssetRecordStore assets;
  final AlbumStore albums;
  final PersonStore people;
  final SyncStore store;
  final BackupTargetsStore targets;
  late final CloudSync sync;

  Future<void> photo(String id, {String description = ''}) async {
    await assets.upsert(localId: id, contentHash: id, platform: 'ios');
    await assets.updateDerivative(
      id,
      DerivativeKind.original,
      DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'originals/$id.HEIC',
      ),
    );
    if (description.isNotEmpty) await assets.setDescription(id, description);
  }

  Future<Album> album(String id) async => (await albums.getById(id))!;

  Future<void> rename(String id, String name) async =>
      albums.update((await album(id)).copyWith(name: name));

  Future<void> close() async {
    await assets.close();
    await albums.close();
    await people.close();
    await store.close();
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late MemoryLogBucket bucket;
  late BackupTargetsStore targets;
  late S3BackupTarget home;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pv_cloud_');
    bucket = MemoryLogBucket();
    targets = BackupTargetsStore(store: FakeSecureStore());
    home = await targets.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'b',
      prefix: '',
    );
  });
  tearDown(() => dir.delete(recursive: true));

  Future<_Phone> phone(String name) async {
    final ph = _Phone(dir, name, bucket, targets);
    addTearDown(ph.close);
    return ph;
  }

  test('the first phone publishes; the second joins, gets the albums, and edits flow both ways', () async {
    final a = await phone('a');
    await a.photo('A1', description: 'Beach');
    await a.albums.upsert(id: 'L', name: 'Trip');
    await a.albums.addAssets('L', ['A1']);
    await a.sync.enable(home);
    expect(a.sync.status.value.error, isNull);
    expect(
      bucket.objects.keys.where((k) => k.startsWith('sync/checkpoints/')),
      hasLength(1),
    );

    final b = await phone('b');
    await b.sync.enable(home);
    expect(
      (await b.album('L')).name,
      'Trip',
      reason: 'joined: the album is here now',
    );
    expect(await b.albums.localIdsIn('L'), [
      'A1',
    ], reason: 'A1 is here as a cloud-only record, so its membership is too');
    final cloud = (await b.assets.getByLocalId('A1'))!;
    expect(
      (cloud.localDeleted, cloud.platform, cloud.description),
      (true, 'cloud', 'Beach'),
    );

    await b.rename('L', 'Lisbon');
    await b.sync.round();
    await a.sync.round();
    expect((await a.album('L')).name, 'Lisbon');
    expect(await a.albums.localIdsIn('L'), [
      'A1',
    ], reason: 'kept through the rename from the other phone');

    await a.assets.setDescription('A1', 'Beach, day 2');
    await a.sync.round();
    expect(await a.store.waiting(), 0);
  });

  test('both phones rename offline: one winner everywhere, a conflict on both, settled by one resolve', () async {
    final a = await phone('a');
    await a.albums.upsert(id: 'L', name: 'Trip');
    await a.sync.enable(home);
    final b = await phone('b');
    await b.sync.enable(home);

    await a.rename('L', 'Lisbon');
    await b.rename('L', 'Portugal');
    await a.sync.round();
    await b.sync.round();
    await a.sync.round();

    expect((await a.album('L')).name, (await b.album('L')).name);
    expect(a.sync.status.value.conflicts, 1);
    expect(b.sync.status.value.conflicts, 1);

    final c = (await a.sync.conflictsFor('album', 'L')).single;
    await a.sync.resolve(c, 'Lisbon 2026');
    await a.sync.round();
    await b.sync.round();
    expect(a.sync.status.value.conflicts, 0);
    expect(b.sync.status.value.conflicts, 0);
    expect((await b.album('L')).name, 'Lisbon 2026');
  });

  test(
    'a local edit not yet collected is never undone by applying the cloud',
    () async {
      final a = await phone('a');
      await a.albums.upsert(id: 'L', name: 'Trip');
      await a.sync.enable(home);
      final b = await phone('b');
      await b.sync.enable(home);
      await a.rename('L', 'From A');
      await a.sync.round();

      // b edits, and before b collects, b's applier runs on a's rename.
      await b.rename('L', 'From B');
      final applier = Applier(
        store: b.store,
        assets: b.assets.syncDatabase,
        albums: b.albums.syncDatabase,
        people: b.people.syncDatabase,
      );
      final applied = await applier.apply({'album/L'});
      expect(applied.deferred, {'album/L'});
      expect((await b.album('L')).name, 'From B');
    },
  );

  test('applying the cloud captures nothing to send back', () async {
    final a = await phone('a');
    await a.photo('A1');
    await a.albums.upsert(id: 'L', name: 'Trip');
    await a.sync.enable(home);
    final b = await phone('b');
    await b.sync.enable(home);
    await a.rename('L', 'Renamed');
    await a.sync.round();
    await b.sync.round();
    expect((await b.album('L')).name, 'Renamed');
    expect(await readCaptured(await b.albums.syncDatabase()), isEmpty);
    expect(await b.store.waiting(), 0);
  });

  test('a caption typed letter by letter goes up as one op', () async {
    final a = await phone('a');
    await a.photo('A1');
    await a.sync.enable(home);
    final before = bucket.objects.keys
        .where((k) => k.startsWith('sync/log/'))
        .length;
    for (final text in ['B', 'Be', 'Bea', 'Beac', 'Beach']) {
      await a.assets.setDescription('A1', text);
    }
    await a.sync.round();
    final logs =
        bucket.objects.keys.where((k) => k.startsWith('sync/log/')).toList()
          ..sort();
    expect(logs.length, before + 1);
  });

  test('pausing stops the network, not the capture: edits made meanwhile go up on resume', () async {
    final a = await phone('a');
    await a.albums.upsert(id: 'L', name: 'Trip');
    await a.sync.enable(home);
    await a.sync.pause();
    await a.rename('L', 'While paused');
    await a.sync.round();
    final b = await phone('b');
    await b.sync.enable(home);
    expect((await b.album('L')).name, 'Trip');
    await a.sync.resume();
    await b.sync.round();
    expect((await b.album('L')).name, 'While paused');
  });

  test('a browser upload becomes a cloud-only record, joins its album, and goes when purged', () async {
    final a = await phone('a');
    await a.photo('A1');
    await a.albums.upsert(id: 'L', name: 'Trip');
    await a.sync.enable(home);

    var seq = 0;
    Op op(int n, String e, String id, OpKind o, {String? f, Object? x}) => Op(
      h: '${(bucket.clock + 1000 + n).toString().padLeft(13, '0')}-0000',
      d: 'browser',
      seq: seq,
      vv: const {},
      e: e,
      id: id,
      o: o,
      f: f,
      x: x,
    );
    Future<void> browser(List<Op> Function() ops) async {
      seq++;
      final seg = Segment(
        d: 'browser',
        seq: seq,
        vv: {await a.store.device(): 1 << 20},
        ops: ops(),
      );
      await bucket.put(Segment.key('browser', seq), seg.encode());
    }

    await browser(
      () => [
        op(
          1,
          'asset',
          'web:x',
          OpKind.add,
          x: {
            'created_at': 1793414025000,
            'original_key': 'originals/20261028161305_abc.jpg',
            'thumbnail_key': 'thumbnails/20261028161305_abc.jpg',
            'original_hash': 'f' * 64,
            'is_video': 0,
            'width': 4032,
            'height': 3024,
          },
        ),
        op(2, 'album', 'L', OpKind.madd, f: 'members', x: 'web:x'),
      ],
    );
    await a.sync.round();

    final r = (await a.assets.getByLocalId('web:x'))!;
    expect((r.localDeleted, r.platform, r.width), (true, 'cloud', 4032));
    expect(
      r.stateOf(DerivativeKind.original).destinationKey,
      'originals/20261028161305_abc.jpg',
    );
    expect(r.stateOf(DerivativeKind.thumbnail).status, UploadStatus.uploaded);
    expect(await a.albums.localIdsIn('L'), contains('web:x'));
    expect(
      await readCaptured(await a.assets.syncDatabase()),
      isEmpty,
      reason: 'not echoed',
    );

    await a.assets.setFavorite('web:x', true);
    await a.sync.round();
    expect(
      await a.store.waiting(),
      0,
      reason: 'a phone edit to it goes up like any other',
    );

    await browser(
      () => [op(3, 'asset', 'web:x', OpKind.set, f: 'purged', x: 1)],
    );
    await a.sync.round();
    expect(await a.assets.getByLocalId('web:x'), isNull);
    expect(
      await a.assets.getByLocalId('A1'),
      isNotNull,
      reason: "the phone's own are never removed",
    );
  });
}

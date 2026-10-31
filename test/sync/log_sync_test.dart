import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/storage/album_store.dart';
import 'package:photos_vault/sync/capture.dart';
import 'package:photos_vault/sync/log_sync.dart';
import 'package:photos_vault/sync/merge.dart';
import 'package:photos_vault/sync/sync_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'memory_log_bucket.dart';

class _Phone {
  _Phone(Directory dir, String name, MemoryLogBucket bucket)
    : albums = AlbumStore(
        databaseFactory: databaseFactoryFfi,
        path: p.join(dir.path, '$name-albums.db'),
      ),
      store = SyncStore(
        databaseFactory: databaseFactoryFfi,
        path: p.join(dir.path, '$name-sync.db'),
      ) {
    sync = LogSync(
      store: store,
      bucket: bucket,
      sources: [albums.syncDatabase],
      privateAssets: (_) async => {},
    );
  }

  final AlbumStore albums;
  final SyncStore store;
  late final LogSync sync;

  Future<void> start() async =>
      setCapture(await albums.syncDatabase(), enabled: true);

  Future<EntityState?> album(String id) async {
    final s = SyncState();
    await store.loadInto(s, ['album/$id']);
    return s.entities['album/$id'];
  }

  Future<void> close() async {
    await albums.close();
    await store.close();
  }
}

void main() {
  setUpAll(sqfliteFfiInit);
  late Directory dir;
  late MemoryLogBucket bucket;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pv_sync_');
    bucket = MemoryLogBucket();
  });
  tearDown(() => dir.delete(recursive: true));

  Future<_Phone> phone(String name) async {
    final ph = _Phone(dir, name, bucket);
    addTearDown(ph.close);
    await ph.start();
    return ph;
  }

  test('two phones rename one album at once: same winner on both, the loser kept as a conflict', () async {
    final a = await phone('a');
    final b = await phone('b');
    await a.albums.upsert(id: 'L', name: 'Trip');
    expect(await a.sync.flush(), 1);
    await b.sync.pull();
    expect((await b.album('L'))!.fields['name']!.x, 'Trip');

    await a.albums.update(
      (await a.albums.getById('L'))!.copyWith(name: 'Lisbon'),
    );
    await b.albums.upsert(id: 'L', name: 'Portugal');
    await a.sync.flush();
    await b.sync.flush();
    await a.sync.pull();
    await b.sync.pull();

    final onA = (await a.album('L'))!;
    final onB = (await b.album('L'))!;
    expect(onA.fields['name']!.x, onB.fields['name']!.x);
    expect(onA.heads['name']!.map((h) => h.x).toSet(), {'Lisbon', 'Portugal'});
    expect((await a.store.conflicted()).entities.keys, ['album/L']);
    expect((await b.store.conflicted()).entities.keys, ['album/L']);
  });

  test('a membership added while another phone removes it survives', () async {
    final a = await phone('a');
    final b = await phone('b');
    await a.albums.upsert(id: 'L', name: 'Kids');
    await a.albums.addAssets('L', ['X']);
    await a.sync.flush();
    await b.sync.pull();

    await b.albums.upsert(id: 'L', name: 'Kids');
    await b.albums.removeAsset('L', 'X');
    await a.albums.removeAsset('L', 'X');
    await a.albums.addAssets('L', ['X']);
    await a.sync.flush();
    await b.sync.flush();
    await a.sync.pull();
    await b.sync.pull();

    expect((await a.album('L'))!.members('members'), ['X']);
    expect((await b.album('L'))!.members('members'), ['X']);
  });

  test(
    'a PUT whose answer was lost is retried without loss or a second copy',
    () async {
      final a = await phone('a');
      await a.albums.upsert(id: 'L', name: 'Trip');
      bucket.dropAnswerAfterNextPut = true;
      await expectLater(a.sync.flush(), throwsA(anything));
      expect(await a.store.waiting(), 1);
      expect(await a.sync.flush(), 1);
      expect(await a.store.waiting(), 0);
      expect(
        bucket.objects.keys.where((k) => k.startsWith('sync/log/')),
        hasLength(1),
      );
    },
  );

  test('someone else at our key: stop writing, keep the edit', () async {
    final a = await phone('a');
    await bucket.put(
      'sync/log/${await a.store.device()}/000000000001.ndjson.gz',
      [1, 2, 3],
    );
    await a.albums.upsert(id: 'L', name: 'Trip');
    expect(await a.sync.flush(), 0);
    expect(await a.sync.fatal(), SyncFatal.collision);
    expect(await a.store.waiting(), 1);
  });

  test('a checkpoint carries the whole state to a new phone', () async {
    final a = await phone('a');
    await a.albums.upsert(id: 'L', name: 'Trip');
    await a.albums.addAssets('L', ['X', 'Y']);
    await a.sync.flush();
    await a.sync.publishCheckpoint();

    final b = await phone('b');
    expect(await b.sync.adoptCheckpoint(), isTrue);
    expect((await b.album('L'))!.members('members'), ['X', 'Y']);
    await a.albums.addAssets('L', ['Z']);
    await a.sync.flush();
    await b.sync.pull();
    expect((await b.album('L'))!.members('members'), ['X', 'Y', 'Z']);
  });

  test('a restored sync.db re-queues its unsent edits under the new phone\'s own id', () async {
    final a = await phone('a');
    await a.albums.upsert(id: 'L', name: 'Never sent');
    await a.sync.seal();
    final copy = p.join(dir.path, 'backup-sync.db');
    expect(await a.store.copyTo(copy), isTrue);

    final fresh = SyncStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, 'fresh.db'),
    );
    addTearDown(fresh.close);
    expect(await fresh.device(), isNot(await a.store.device()));
    expect(await fresh.mergeFrom(copy), 1);
    final queued = await fresh.outbox();
    expect(queued.single.$2.x, isA<Map>());
    expect((queued.single.$2.x as Map)['name'], 'Never sent');
  });
}

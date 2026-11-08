import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/photos/travel.dart';
import 'package:photos_vault/photos/travel_store.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/album.dart';
import 'package:photos_vault/storage/album_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/sync/apply.dart';
import 'package:photos_vault/sync/capture.dart';
import 'package:photos_vault/sync/bootstrap.dart';
import 'package:photos_vault/sync/cloud_sync.dart';
import 'package:photos_vault/sync/merge.dart';
import 'package:photos_vault/sync/op.dart';
import 'package:photos_vault/sync/segment.dart';
import 'package:photos_vault/sync/sync_store.dart';
import 'package:photos_vault/sync/translate.dart';
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
      travel = TravelStore(
        databaseFactory: databaseFactoryFfi,
        path: p.join(dir.path, '$name-travel.db'),
      ),
      store = SyncStore(
        databaseFactory: databaseFactoryFfi,
        path: p.join(dir.path, '$name-sync.db'),
      ) {
    sync = CloudSync(
      assets: assets,
      albums: albums,
      people: people,
      travel: travel,
      targets: targets,
      store: store,
      bucketFor: (_) => bucket,
    );
  }

  final AssetRecordStore assets;
  final AlbumStore albums;
  final PersonStore people;
  final TravelStore travel;
  final SyncStore store;
  final BackupTargetsStore targets;
  late CloudSync sync;

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
    await travel.close();
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

  test('a date set on another device is a set date here: Photos\' own '
      'date no longer replaces it', () async {
    final a = await phone('a');
    await a.photo('A1');
    await a.photo('A2');
    await a.sync.enable(home);
    final b = await phone('b');
    await b.sync.enable(home);

    final chosen = DateTime(1999, 5, 1);
    await b.assets.setCreatedAtMany({'A1': chosen});
    await b.assets.setDescription('A2', 'Lake');
    await b.sync.round();
    await a.sync.round();

    final dated = (await a.assets.getByLocalId('A1'))!;
    expect(dated.createdAt, chosen);
    expect(dated.dateSetAt, isNotNull);
    expect(await a.assets.setLibraryDate('A1', DateTime(2020)), isFalse);
    final other = (await a.assets.getByLocalId('A2'))!;
    expect(other.description, 'Lake');
    expect(other.dateSetAt, isNull, reason: 'its date never moved');
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

  group('profiles', () {
    Future<Person> mia(_Phone ph) async {
      final mia = await ph.people.create(name: 'Mia', id: 'mia');
      final dan = await ph.people.create(name: 'Dan', id: 'dan');
      await ph.people.update(
        mia.copyWith(
          firstName: 'Mia',
          lastName: 'Rossi',
          avatarFace: () => const FaceRect(0.1, 0.2, 0.3, 0.4),
        ),
      );
      await ph.people.saveDetail(
        mia.id,
        const PersonDetail(traits: {'hair': 'red'}),
        scope: PersonScope.open,
      );
      await ph.people.saveEvent(
        PersonEvent(
          id: 'ev1',
          personId: mia.id,
          type: PersonEventType.firstMet,
          at: DateTime(2019, 6, 1),
          notes: 'Lisbon',
        ),
        scope: PersonScope.open,
      );
      await ph.people.joinGroup(
        mia.id,
        const PersonGroup(id: 'g1', name: 'Uni', kind: GroupKind.school),
        scope: PersonScope.open,
      );
      await ph.people.addRelationship(
        mia.id,
        dan.id,
        RelationshipType.spouse,
        scope: PersonScope.open,
      );
      return mia;
    }

    test('a profile reaches the second phone, and edits come back', () async {
      final a = await phone('a');
      final m = await mia(a);
      await a.sync.enable(home);

      final b = await phone('b');
      await b.sync.enable(home);
      final got = (await b.people.getById(m.id))!;
      expect((got.firstName, got.lastName), ('Mia', 'Rossi'));
      expect(got.avatarFace, const FaceRect(0.1, 0.2, 0.3, 0.4));
      expect((await b.people.detailFor(m.id)).traits['hair'], 'red');
      expect(
        [for (final e in await b.people.eventsFor(m.id)) e.notes],
        ['Lisbon'],
      );
      expect([for (final g in await b.people.groupsFor(m.id)) g.name], ['Uni']);
      expect(
        [
          for (final r in await b.people.relationshipsFor(m.id))
            r.relatedPersonId,
        ],
        ['dan'],
      );

      await b.people.removeEvent('ev1', scope: PersonScope.open);
      await b.people.saveEvent(
        PersonEvent(
          id: 'ev2',
          personId: m.id,
          type: PersonEventType.trip,
          at: DateTime(2020),
          notes: 'Porto',
        ),
        scope: PersonScope.open,
      );
      await b.sync.round();
      await a.sync.round();
      expect(
        [for (final e in await a.people.eventsFor(m.id)) e.notes],
        ['Porto'],
      );
    });

    test('a phone that synced before profiles did sends its rows once, '
        'and nothing of its own is lost', () async {
      final a = await phone('a');
      final m = await mia(a);
      await a.sync.enable(home);
      final b = await phone('b');
      await b.sync.enable(home);
      // A row from before profiles were captured: never sent.
      final db = await b.people.syncDatabase();
      await setCapture(db, enabled: false);
      await b.people.saveEvent(
        PersonEvent(
          id: 'evB',
          personId: m.id,
          type: PersonEventType.trip,
          at: DateTime(2021),
          notes: 'Only on B',
        ),
        scope: PersonScope.open,
      );
      await setCapture(db, enabled: true);
      await b.store.setMeta('profiles_joined', false);

      await b.sync.round();
      await a.sync.round();
      expect(await b.store.meta('profiles_joined'), 'true');
      for (final ph in [a, b]) {
        expect(
          {for (final e in await ph.people.eventsFor(m.id)) e.notes},
          {'Lisbon', 'Only on B'},
        );
      }
    });

    test('a group range syncs, and a change to it comes back', () async {
      final a = await phone('a');
      final m = await mia(a);
      await a.people.updateGroup(
        'g1',
        range: (start: DateTime(2010, 9, 1), end: DateTime(2014, 6, 1)),
      );
      await a.sync.enable(home);
      final b = await phone('b');
      await b.sync.enable(home);
      var g = (await b.people.groupsFor(m.id)).single;
      expect((g.start, g.end), (DateTime(2010, 9, 1), DateTime(2014, 6, 1)));

      await b.people.updateGroup(
        'g1',
        range: (start: DateTime(2009), end: null),
      );
      await b.sync.round();
      await a.sync.round();
      g = (await a.people.groupsFor(m.id)).single;
      expect((g.name, g.start, g.end), ('Uni', DateTime(2009), null));
    });

    test('an undated group is the same member it was before ranges', () {
      expect(
        profileMember('person_group', {
          'group_id': 'g',
          'name': 'Uni',
          'kind': 'school',
          'start_date': null,
          'end_date': null,
        }),
        '{"group_id":"g","name":"Uni","kind":"school"}',
      );
    });

    test('a profile behind a passcode never leaves the phone', () async {
      final a = await phone('a');
      final m = await mia(a);
      await a.people.update(
        (await a.people.getById(m.id))!.copyWith(passcodeHash: () => 'h'),
      );
      await a.sync.enable(home);
      final b = await phone('b');
      await b.sync.enable(home);
      expect(await b.people.getById(m.id), isNull);
      expect(await b.people.eventsFor(m.id), isEmpty);
    });
  });

  group('travel', () {
    Future<(Place, Place, TravelEntry, TravelRoute)> trip(_Phone a) async {
      final kyoto = await a.travel.findOrCreateCity(
        name: 'Kyoto',
        country: 'Japan',
        lat: 35.0,
        lng: 135.7,
      );
      final gion = await a.travel.createPlace(
        name: 'Gion',
        kind: PlaceKind.point,
        lat: 35.003,
        lng: 135.775,
        parentId: kyoto.id,
      );
      final entry = await a.travel.saveEntry(
        a.travel
            .newEntry(
              placeId: gion.id,
              kind: EntryKind.impression,
              at: DateTime(2017, 4, 3),
            )
            .copyWith(
              title: 'Lanterns',
              text: 'Quiet at dusk',
              rating: () => 4,
              tags: ['night', 'walk'],
            ),
      );
      await a.travel.setLinks(LinkOwner.entry, entry.id, const [
        TravelLink(LinkTarget.asset, 'A1'),
      ]);
      final route = await a.travel.createRoute(title: 'Kansai');
      await a.travel.setStops(route.id, [
        RouteStop(placeId: kyoto.id, arrived: DateTime(2017, 4, 2)),
        RouteStop(placeId: gion.id, note: 'Dinner'),
      ]);
      return (kyoto, gion, entry, route);
    }

    test('places, impressions and plans reach the second phone, and edits come back', () async {
      final a = await phone('a');
      await a.photo('A1');
      final (kyoto, gion, entry, route) = await trip(a);
      await a.sync.enable(home);
      expect(a.sync.status.value.error, isNull);

      final b = await phone('b');
      await b.sync.enable(home);
      expect(b.sync.status.value.error, isNull);
      final places = {for (final p in await b.travel.places()) p.id: p};
      expect(places[gion.id]?.parentId, kyoto.id);
      expect(places[kyoto.id]?.parentId, isNotNull, reason: 'under Japan');
      final got = (await b.travel.entry(entry.id))!;
      expect(
        (got.title, got.text, got.rating),
        ('Lanterns', 'Quiet at dusk', 4),
      );
      expect(got.tags, ['night', 'walk']);
      expect(
        (await b.travel.linksFor(LinkOwner.entry, [entry.id]))[entry.id],
        const [TravelLink(LinkTarget.asset, 'A1')],
      );
      final detail = (await b.travel.routeDetail(route.id))!;
      expect(
        [for (final s in detail.stops) (s.placeId, s.note)],
        [(kyoto.id, ''), (gion.id, 'Dinner')],
      );
      expect(detail.stops.first.arrived, DateTime(2017, 4, 2));

      await b.travel.saveEntry(
        got.copyWith(text: 'Quiet at dusk, loud at ten', tags: ['night']),
      );
      await b.travel.deleteRoute(route.id);
      await b.sync.round();
      await a.sync.round();
      final back = (await a.travel.entry(entry.id))!;
      expect(back.text, 'Quiet at dusk, loud at ten');
      expect(back.tags, ['night']);
      expect(await a.travel.routeDetail(route.id), isNull);
    });

    test(
      'a phone that synced before travel did sends its travel once',
      () async {
        final a = await phone('a');
        final (_, gion, _, _) = await trip(a);
        a.sync = CloudSync(
          assets: a.assets,
          albums: a.albums,
          people: a.people,
          targets: targets,
          store: a.store,
          bucketFor: (_) => bucket,
        );
        await a.sync.enable(home);
        a.sync = CloudSync(
          assets: a.assets,
          albums: a.albums,
          people: a.people,
          travel: a.travel,
          targets: targets,
          store: a.store,
          bucketFor: (_) => bucket,
        );
        await a.sync.round();
        expect(await a.store.meta('travel_joined'), 'true');

        final b = await phone('b');
        await b.sync.enable(home);
        expect((await b.travel.place(gion.id))?.name, 'Gion');
      },
    );

    test('a phone that pulled plans on a build that couldn\'t write them '
        'writes them once it can', () async {
      final a = await phone('a');
      final (_, gion, _, _) = await trip(a);
      await a.sync.enable(home);
      final b = await phone('b');
      final travel = b.sync;
      b.sync = CloudSync(
        assets: b.assets,
        albums: b.albums,
        people: b.people,
        targets: targets,
        store: b.store,
        bucketFor: (_) => bucket,
      );
      await b.sync.enable(home);
      expect(await b.travel.place(gion.id), isNull);
      await b.store.setMeta('applier_version', 1);

      b.sync = travel;
      await b.sync.round();
      expect((await b.travel.place(gion.id))?.name, 'Gion');
      expect(
        await b.store.meta('applier_version'),
        '${CloudSync.applierVersion}',
      );
    });

    test('a link to a hidden photo never leaves the phone', () async {
      final a = await phone('a');
      await a.photo('A1');
      await a.photo('H1');
      await a.assets.setPasscodeHash('H1', 'hash');
      final (_, _, entry, _) = await trip(a);
      await a.travel.setLinks(LinkOwner.entry, entry.id, const [
        TravelLink(LinkTarget.asset, 'A1'),
        TravelLink(LinkTarget.asset, 'H1'),
      ]);
      await a.sync.enable(home);
      final b = await phone('b');
      await b.sync.enable(home);
      expect(
        (await b.travel.linksFor(LinkOwner.entry, [entry.id]))[entry.id],
        const [TravelLink(LinkTarget.asset, 'A1')],
      );
      await a.sync.round();
      expect(
        (await a.travel.linksFor(LinkOwner.entry, [entry.id]))[entry.id],
        hasLength(2),
        reason: 'the cloud not naming it is no reason to drop it here',
      );
    });
  });

  group('presence', () {
    Future<EntityState> cloud(_Phone ph, String id) async {
      final s = SyncState();
      await ph.store.loadInto(s, ['asset/$id']);
      return s.entities['asset/$id']!;
    }

    // As `extension/src/model.ts` reads it.
    bool cloudOnly(EntityState ent) =>
        (ent.fields[presenceMarker]?.x != null ||
            ent.sets.containsKey(presenceSet)) &&
        ent.members(presenceSet).isEmpty;

    Future<void> outside(_Phone ph, Future<void> Function() write) async {
      final db = await ph.assets.syncDatabase();
      await setCapture(db, enabled: false);
      await write();
      await setCapture(db, enabled: true);
    }

    test(
      'each phone adds and removes only itself; empty is cloud-only',
      () async {
        final a = await phone('a');
        await a.photo('A1');
        await a.sync.enable(home);
        final b = await phone('b');
        await b.sync.enable(home);
        final da = await a.store.device();
        final db = await b.store.device();

        var ent = await cloud(b, 'A1');
        expect(ent.members(presenceSet), [da]);
        expect(cloudOnly(ent), isFalse);
        expect(
          (await b.assets.getByLocalId('A1'))!.localDeleted,
          isTrue,
          reason: 'the record b has from the cloud says nothing for b',
        );

        // b downloads it, a frees its copy.
        await b.assets.setLocalDeleted('A1', false);
        await b.sync.round();
        await a.sync.round();
        expect(
          (await cloud(a, 'A1')).members(presenceSet),
          {da, db}.toList()..sort(),
        );
        await a.assets.setLocalDeleted('A1', true);
        await a.sync.round();
        await b.sync.round();
        ent = await cloud(b, 'A1');
        expect(ent.members(presenceSet), [db]);
        expect(cloudOnly(ent), isFalse);

        await b.assets.setLocalDeleted('A1', true);
        await b.sync.round();
        await a.sync.round();
        for (final ph in [a, b]) {
          ent = await cloud(ph, 'A1');
          expect(ent.members(presenceSet), isEmpty);
          expect(cloudOnly(ent), isTrue);
        }
      },
    );

    test('a phone that synced before presence backfills once, '
        'and only what changed', () async {
      final a = await phone('a');
      for (final id in ['H', 'F', 'K']) {
        await a.photo(id);
      }
      await a.sync.enable(home);
      final da = await a.store.device();
      // Freed and re-held on a build that sent no presence.
      await outside(a, () => a.assets.setLocalDeleted('F', true));
      await a.store.setMeta('presence_joined', false);

      final sent = bucket.objects.keys.where((k) => k.contains('/log/')).length;
      await a.sync.round();
      expect(await a.store.meta('presence_joined'), 'true');
      expect(
        bucket.objects.keys.where((k) => k.contains('/log/')).length,
        sent + 1,
        reason: 'one segment for the whole backfill',
      );
      expect((await cloud(a, 'F')).members(presenceSet), isEmpty);
      expect(cloudOnly(await cloud(a, 'F')), isTrue);
      expect((await cloud(a, 'H')).members(presenceSet), [da]);

      expect(
        await queuePresence(
          store: a.store,
          assets: await a.assets.syncDatabase(),
        ),
        0,
        reason: 'compared against the merged state: nothing new to say',
      );
      final after = bucket.objects.keys
          .where((k) => k.contains('/log/'))
          .length;
      await a.sync.round();
      expect(
        bucket.objects.keys.where((k) => k.contains('/log/')).length,
        after,
        reason: 'nothing changed, nothing sent',
      );
    });

    test('never reported is unknown, not cloud-only', () async {
      final a = await phone('a');
      await a.photo('OWN');
      await a.sync.enable(home);

      // An older phone's photo and a browser upload: no presence at all.
      var seq = 0;
      Future<void> older(String d, String id) async {
        seq++;
        final op = Op(
          h: '${(bucket.clock + 1000 + seq).toString().padLeft(13, '0')}-0000',
          d: d,
          seq: 1,
          vv: const {},
          e: 'asset',
          id: id,
          o: OpKind.add,
          x: {'original_key': 'originals/$id.jpg', 'created_at': 1},
        );
        await bucket.put(
          Segment.key(d, 1),
          Segment(d: d, seq: 1, vv: const {}, ops: [op]).encode(),
        );
      }

      await older('oldphone', 'OLD1');
      await older('browser', 'web:y');
      await a.sync.round();
      expect((await a.assets.getByLocalId('web:y'))!.localDeleted, isTrue);

      // Even a backfill from a phone holding cloud records of them.
      await a.store.setMeta('presence_joined', false);
      await a.sync.round();
      for (final id in ['OLD1', 'web:y']) {
        final ent = await cloud(a, id);
        expect(ent.fields[presenceMarker], isNull, reason: id);
        expect(cloudOnly(ent), isFalse, reason: id);
      }
      expect(cloudOnly(await cloud(a, 'OWN')), isFalse);
    });

    test(
      'a restored sync.db does not replay the old phone\'s presence',
      () async {
        final a = await phone('a');
        await a.photo('A1');
        await a.sync.enable(home);
        await a.store.addChanges([
          ...presence('A1', held: false),
          const Change('asset', 'A1', OpKind.set, f: 'is_favorite', x: 1),
        ]);
        await a.store.close();

        final b = await phone('b');
        await b.store.mergeFrom(p.join(dir.path, 'a-sync.db'));
        expect(
          [for (final (_, c) in await b.store.outbox()) c.f],
          [presenceMarker, 'is_favorite'],
          reason: 'the new phone sends its own presence',
        );
      },
    );
  });
}

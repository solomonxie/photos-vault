import 'dart:io';

import 'package:photos_vault/photos/demo_assets_service.dart';
import 'package:photos_vault/photos/manual_add.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/storage/album_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  AssetRecordStore newStore() {
    final store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return store;
  }

  // A real (temp) file, not `inMemoryDatabasePath` — sqflite's default
  // `singleInstance: true` caches open connections keyed by that literal
  // path string across every store in the process, so an `AssetRecordStore`
  // and an `AlbumStore` both opened against `:memory:` in the same test
  // would silently share one connection (and thus one schema) instead of
  // getting independent databases.
  AlbumStore newAlbumStore() {
    final dir = Directory.systemTemp.createTempSync('album_store_test_');
    final store = AlbumStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, 'albums.db'),
    );
    addTearDown(() async {
      await store.close();
      await dir.delete(recursive: true);
    });
    return store;
  }

  PersonStore newPersonStore() {
    final dir = Directory.systemTemp.createTempSync('person_store_test_');
    final store = PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: p.join(dir.path, 'people.db'),
    );
    addTearDown(() async {
      await store.close();
      await dir.delete(recursive: true);
    });
    return store;
  }

  DemoAssetsService newService({
    AssetRecordStore? store,
    AlbumStore? albumStore,
    PersonStore? personStore,
  }) => DemoAssetsService(
    manualAddService: ManualAddService(
      store: store ?? newStore(),
      targetDirectory: () async => Directory.systemTemp,
    ),
    albumStore: albumStore ?? newAlbumStore(),
    personStore: personStore ?? newPersonStore(),
    targetDirectory: () async => Directory.systemTemp,
  );

  test('addAll enqueues every bundled demo asset as a manual file', () async {
    final store = newStore();
    final service = newService(store: store);

    final added = await service.addAll();

    expect(added, hasLength(DemoAssetsService.assetPaths.length));
    for (final record in added) {
      expect(record.sourceType, AssetSourceType.manualFile);
      expect(record.sourcePath, isNotNull);
    }
    expect(
      await store.listAll(),
      hasLength(DemoAssetsService.assetPaths.length),
    );
  });

  test(
    'addAll groups demo assets into 5 days across 3 years, not one day each',
    () async {
      final service = newService();

      final added = await service.addAll();

      final days = added
          .map(
            (r) =>
                DateTime(r.createdAt.year, r.createdAt.month, r.createdAt.day),
          )
          .toSet();
      final years = added.map((r) => r.createdAt.year).toSet();
      expect(days, hasLength(5));
      expect(years, hasLength(3));
    },
  );

  test('addAll is a no-op for demo assets already present', () async {
    final store = newStore();
    final service = newService(store: store);

    await service.addAll();
    await service.addAll();

    expect(
      await store.listAll(),
      hasLength(DemoAssetsService.assetPaths.length),
    );
  });

  test(
    'addAll re-creates a demo asset that was deleted (reset behavior)',
    () async {
      final store = newStore();
      final service = newService(store: store);
      await service.addAll();
      final firstRecord = (await store.listAll()).first;

      await store.remove(firstRecord.localId);
      expect(
        await store.listAll(),
        hasLength(DemoAssetsService.assetPaths.length - 1),
      );

      await service.addAll();

      expect(
        await store.listAll(),
        hasLength(DemoAssetsService.assetPaths.length),
      );
    },
  );

  test(
    'addAll seeds preset demo albums with members from the added assets',
    () async {
      final albumStore = newAlbumStore();
      final service = newService(albumStore: albumStore);

      await service.addAll();

      final albums = await albumStore.listAll();
      expect(albums, hasLength(3));
      expect(albums.every((a) => a.isDemo), isTrue);
      for (final album in albums) {
        expect(await albumStore.localIdsIn(album.id), isNotEmpty);
      }
    },
  );

  test('addAll re-populates a demo album deleted since the last run', () async {
    final albumStore = newAlbumStore();
    final service = newService(albumStore: albumStore);
    await service.addAll();
    final firstAlbum = (await albumStore.listAll()).first;

    await albumStore.remove(firstAlbum.id);
    expect(await albumStore.getById(firstAlbum.id), isNull);

    await service.addAll();

    final restored = await albumStore.getById(firstAlbum.id);
    expect(restored, isNotNull);
    expect(await albumStore.localIdsIn(firstAlbum.id), isNotEmpty);
  });

  test(
    'addAll seeds a demo Private Album tagged with its passcode hash',
    () async {
      final store = newStore();
      final service = newService(store: store);

      await service.addAll();

      final hash = hashPasscode(DemoAssetsService.demoPrivateAlbumPasscode);
      final tagged = await store.forPasscodeHash(hash);
      expect(tagged, hasLength(3));
    },
  );

  test(
    'addAll seeds demo people with profiles, tagged photos, and a relationship',
    () async {
      final personStore = newPersonStore();
      final service = newService(personStore: personStore);

      await service.addAll();

      final people = await personStore.listAll();
      expect(
        people.map((p) => p.name),
        containsAll(['Mia Chen', 'Daniel Wong', 'Grandma Lily']),
      );
      final trio = people.where(
        (p) =>
            p.id.startsWith('demo-person-mia') ||
            p.id == 'demo-person-daniel' ||
            p.id == 'demo-person-grandma-lily',
      );
      for (final person in trio) {
        expect(person.isDemo, isTrue);
        expect(person.avatarLocalId, isNotNull);
        expect(await personStore.localIdsIn(person.id), isNotEmpty);
      }
      final mia = people.firstWhere((p) => p.id == 'demo-person-mia');
      final relationships = await personStore.relationshipsFor(mia.id);
      expect(relationships, hasLength(2));
      expect(
        await personStore.locationsFor('demo-person-grandma-lily'),
        hasLength(2),
      );
      expect(
        (await personStore.historyFor(
          mia.id,
          HistoryCategory.education,
        )).single.title,
        'UC Berkeley',
      );
      expect(
        (await personStore.historyFor(
          mia.id,
          HistoryCategory.job,
        )).single.title,
        'Product Designer',
      );
    },
  );

  test('addAll is idempotent for demo people (no duplicate locations/history on reset)', () async {
    final personStore = newPersonStore();
    final service = newService(personStore: personStore);

    await service.addAll();
    final countAfterFirst = (await personStore.listAll()).length;
    await service.addAll();

    expect(await personStore.listAll(), hasLength(countAfterFirst));
    expect(
      await personStore.locationsFor('demo-person-grandma-lily'),
      hasLength(2),
    );
    expect(
      await personStore.historyFor(
        'demo-person-mia',
        HistoryCategory.education,
      ),
      hasLength(1),
    );
  });

  test(
    'addAll seeds Marcus Bennett\'s network covering every relationship type',
    () async {
      final personStore = newPersonStore();
      final service = newService(personStore: personStore);

      await service.addAll();

      final marcus = await personStore.getById('demo-person-marcus');
      expect(marcus, isNotNull);
      expect(marcus!.isDemo, isTrue);
      expect(marcus.avatarLocalId, isNotNull);

      final relationships = await personStore.relationshipsFor(
        'demo-person-marcus',
      );
      expect(relationships, hasLength(15));
      expect(
        relationships.map((r) => r.type).toSet(),
        RelationshipType.values.toSet(),
      );

      final colleague = relationships.singleWhere(
        (r) => r.relatedPersonId == 'demo-person-sarah-kim',
      );
      expect(colleague.type, RelationshipType.colleague);
      expect(colleague.organization, 'Nimbus Systems');
      final schoolmate = relationships.singleWhere(
        (r) => r.relatedPersonId == 'demo-person-ben',
      );
      expect(schoolmate.organization, 'Ohio State University');

      expect(
        await personStore.allOrganizations(),
        containsAll([
          'Nimbus Systems',
          'BrightPath Retail',
          'Ohio State University',
          'Cleveland Heights High School',
          'Seattle Road Runners',
        ]),
      );

      final locations = await personStore.locationsFor('demo-person-marcus');
      expect(locations, hasLength(4));
      expect(locations.first.place, 'Cleveland, OH');
      expect(locations.first.kind, LocationKind.origin);

      expect(
        (await personStore.historyFor(
          'demo-person-marcus',
          HistoryCategory.education,
        )).single.title,
        'Ohio State University',
      );
      expect(
        (await personStore.historyFor(
          'demo-person-marcus',
          HistoryCategory.job,
        )).single.title,
        'Engineering Manager',
      );
      expect(
        (await personStore.historyFor(
          'demo-person-sarah-kim',
          HistoryCategory.job,
        )).single.title,
        'Product Manager at Nimbus Systems',
      );
    },
  );

  test('addAll is idempotent for Marcus\'s network (no duplicate relationships/locations/history on reset)', () async {
    final personStore = newPersonStore();
    final service = newService(personStore: personStore);

    await service.addAll();
    await service.addAll();

    expect(
      await personStore.relationshipsFor('demo-person-marcus'),
      hasLength(15),
    );
    expect(await personStore.locationsFor('demo-person-marcus'), hasLength(4));
    expect(
      await personStore.historyFor(
        'demo-person-marcus',
        HistoryCategory.education,
      ),
      hasLength(1),
    );
  });
}

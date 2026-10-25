import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/ai_analysis_store.dart';
import 'package:photos_vault/photos/face_file.dart';
import 'package:photos_vault/photos/face_import.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

Person person(String id, String name) {
  final at = DateTime(2024);
  return Person(id: id, name: name, createdAt: at, updatedAt: at);
}

FileFace face(FaceRect box, String name, {String photo = 'k'}) =>
    (photo: photo, face: FaceFileFace(box, name));

void main() {
  const vision = FaceRect(0.40, 0.20, 0.16, 0.22);

  group('box matching', () {
    test('a third of overlap, or the centre inside, is the same face', () {
      expect(boxesAgree(const FaceRect(0.42, 0.24, 0.12, 0.16), vision), true);
      // Small box, low IoU, but centred inside.
      expect(boxesAgree(const FaceRect(0.46, 0.28, 0.04, 0.04), vision), true);
      expect(boxesAgree(const FaceRect(0.7, 0.7, 0.1, 0.1), vision), false);
    });

    test('closest wins, each found face once', () {
      const a = FaceRect(0.1, 0.1, 0.2, 0.2);
      const b = FaceRect(0.15, 0.1, 0.2, 0.2);
      final found = [const FaceRect(0.15, 0.1, 0.2, 0.2)];
      expect(matchBoxes([a, b], found), {1: 0});
    });
  });

  group('resolveFacePhotos', () {
    test('key stem first, hash failing that, the rest counted', () {
      final file = FaceFile(
        photos: [
          FaceFilePhoto(key: '2024_a', faces: [FaceFileFace(vision, 'A')]),
          FaceFilePhoto(
            key: 'nope',
            sha256: 'ff',
            faces: [FaceFileFace(vision, 'B')],
          ),
          FaceFilePhoto(key: 'gone', faces: [FaceFileFace(vision, 'C')]),
        ],
      );
      final r = resolveFacePhotos(file, [
        (localId: 'p1', key: 'pre/originals/2024_a.heic', hash: null),
        (localId: 'p2', key: 'originals/other.jpg', hash: 'FF'),
      ]);
      expect(r.photos.keys, ['p1', 'p2']);
      expect(r.unknown, 1);
    });
  });

  group('planFaceImport', () {
    final alice = person('alice', 'Alice');
    final bob = person('bob', 'Bob');

    FaceImportPlan plan(
      Map<String, List<FileFace>> photos, {
      Set<String> visible = const {'p'},
      Map<String, ({List<FaceRect> faces, bool legacy})> rows = const {},
      Map<String, Map<FaceRect, String>> named = const {},
      List<Person>? people,
    }) => planFaceImport(
      photos: photos,
      visible: visible,
      rows: rows,
      named: named,
      people: people ?? [alice, bob],
    );

    test('names a found face by name, case-insensitively', () {
      final p = plan(
        {
          'p': [face(const FaceRect(0.41, 0.21, 0.15, 0.2), 'alice')],
        },
        rows: {
          'p': (faces: [vision], legacy: false),
        },
      );
      final link = p.links.single;
      expect(link.personId, 'alice');
      expect(link.face, vision);
      expect(link.added, false);
      expect(p.newPeople, isEmpty);
    });

    test('no found face adds the file box; unknown name is a new person', () {
      const box = FaceRect(0.7, 0.7, 0.1, 0.1);
      final p = plan(
        {
          'p': [face(box, 'Carol'), face(vision, 'carol')],
        },
        rows: {
          'p': (faces: [vision], legacy: false),
        },
      );
      expect(p.links.first.added, true);
      expect(p.links.first.face, box);
      expect(p.links.first.newName, 'Carol');
      expect(p.links.last.added, false);
      expect(p.newPeople, ['Carol']);
    });

    test('never overwrites a name; the same name is unchanged', () {
      const other = FaceRect(0.7, 0.7, 0.1, 0.1);
      final p = plan(
        {
          'p': [face(vision, 'Alice'), face(other, 'Alice')],
        },
        rows: {
          'p': (faces: [vision], legacy: false),
        },
        named: {
          'p': {vision: 'bob', other: 'alice'},
        },
      );
      expect(p.links, isEmpty);
      expect(p.unchanged, 1);
      final c = p.conflicts.single;
      expect(c.fileName, 'Alice');
      expect(c.appName, 'Bob');
    });

    test('a name shared by two people is a conflict, not a guess', () {
      final p = plan(
        {
          'p': [face(vision, 'Alice')],
        },
        people: [alice, person('alice2', 'ALICE')],
      );
      expect(p.links, isEmpty);
      expect(p.conflicts.single.sharedBy, 2);
    });

    test('hidden, missing and legacy photos are one skipped count', () {
      final p = plan(
        {
          'hidden': [face(vision, 'Alice')],
          'legacy': [face(vision, 'Alice')],
        },
        visible: {'legacy'},
        rows: {
          'legacy': (faces: [vision], legacy: true),
        },
      );
      expect(p.links, isEmpty);
      expect(p.skippedPhotos, 2);
      expect(
        planFaceImport(
          photos: const {},
          visible: const {},
          rows: const {},
          named: const {},
          people: const [],
          unknown: 3,
        ).skippedPhotos,
        3,
      );
    });
  });

  group('importNamedFaces', () {
    setUpAll(sqfliteFfiInit);

    AiAnalysisStore newStore() {
      final store = AiAnalysisStore(
        databaseFactory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(store.close);
      return store;
    }

    test('adds boxes, names faces undescribed, keeps existing names', () async {
      final store = newStore();
      await store.saveFaceCount(
        localId: 'p',
        peopleCount: 1,
        analyzedAt: DateTime(2024),
        faces: [vision],
      );
      const added = FaceRect(0.7, 0.7, 0.1, 0.1);
      final result = await store.importNamedFaces(
        [
          (localId: 'p', face: vision, personId: 'alice'),
          (localId: 'p', face: added, personId: 'bob'),
          (localId: 'q', face: added, personId: 'bob'),
        ],
        added: {
          'p': [added],
          'q': [added],
        },
      );
      expect(result.linked, hasLength(3));
      expect(result.undescribed, {'p', 'q'});
      expect(await store.facesFor('p'), [vision, added]);
      expect(await store.facesFor('q'), [added]);
      expect((await store.get('q'))!.peopleCount, 1);
      expect(await store.namedFacesIn('p'), {vision: 'alice', added: 'bob'});

      final again = await store.importNamedFaces([
        (localId: 'p', face: vision, personId: 'bob'),
      ]);
      expect(again.linked, isEmpty);
      expect((await store.namedFacesIn('p'))[vision], 'alice');
    });
  });

  test('FaceImport: summary first, then one commit links faces', () async {
    final records = FakeAssetRecordStore();
    final analysis = FakeAiAnalysisStore();
    final people = FakePersonStore();
    final alice = await people.create(name: 'Alice');
    for (final (id, hidden) in [('p1', false), ('p2', true)]) {
      await records.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        isHidden: hidden,
        createdAt: DateTime(2024, 6),
      );
      await records.updateDerivative(
        id,
        DerivativeKind.original,
        DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: 'originals/$id.heic',
        ),
      );
    }
    await analysis.saveFaceCount(
      localId: 'p1',
      peopleCount: 1,
      analyzedAt: DateTime(2024),
      faces: [vision],
    );
    final import = FaceImport(
      personStore: people,
      assetRecordStore: records,
      analysisStore: analysis,
    );
    final file = FaceFile(
      photos: [
        FaceFilePhoto(
          key: 'p1',
          faces: [
            FaceFileFace(const FaceRect(0.41, 0.21, 0.15, 0.2), 'ALICE'),
            FaceFileFace(const FaceRect(0.7, 0.7, 0.1, 0.1), 'Dan'),
          ],
        ),
        FaceFilePhoto(key: 'p2', faces: [FaceFileFace(vision, 'Alice')]),
        FaceFilePhoto(key: 'nope', faces: [FaceFileFace(vision, 'Alice')]),
      ],
    );

    final plan = await import.plan(file);
    expect(plan.links, hasLength(2));
    expect(plan.newPeople, ['Dan']);
    expect(plan.skippedPhotos, 2);
    expect(await analysis.namedFacesIn('p1'), isEmpty);

    final done = await import.commit(plan);
    expect(done, (faces: 2, people: 1, grouped: 0));
    final dan = (await people.listAll()).singleWhere((p) => p.name == 'Dan');
    expect(await analysis.namedFacesIn('p1'), {
      vision: alice.id,
      const FaceRect(0.7, 0.7, 0.1, 0.1): dan.id,
    });
    final members = await people.allMemberships();
    expect(members[alice.id], ['p1']);
    expect(members[dan.id], ['p1']);
    expect((await people.getById(dan.id))!.avatarLocalId, 'p1');
  });

  group('face groups', () {
    const other = FaceRect(0.7, 0.7, 0.1, 0.1);

    test('plan: grouped faces match like named ones; named stay out', () {
      final p = planFaceImport(
        photos: {
          'p': [
            (
              photo: 'k',
              face: FaceFileFace.grouped(
                const FaceRect(0.41, 0.21, 0.15, 0.2),
                'g1',
              ),
            ),
            (photo: 'k', face: FaceFileFace.grouped(other, 'g2')),
            (
              photo: 'k',
              face: FaceFileFace.grouped(
                const FaceRect(0.1, 0.1, 0.1, 0.1),
                'g1',
              ),
            ),
          ],
        },
        visible: {'p'},
        rows: {
          'p': (
            faces: [vision, const FaceRect(0.1, 0.1, 0.1, 0.1)],
            legacy: false,
          ),
        },
        named: {
          'p': {const FaceRect(0.1, 0.1, 0.1, 0.1): 'bob'},
        },
        people: const [],
        groups: {'g2': const FaceFileGroup('g2', suggest: 'Ava')},
      );
      expect(p.links, isEmpty);
      expect(p.grouped.map((g) => (g.face, g.groupId, g.added)), [
        (vision, 'g1', false),
        (other, 'g2', true),
      ]);
      expect(p.groups, {'g1': null, 'g2': 'Ava'});
      expect(p.namedNotGrouped, 1);
    });

    test('shownFaceGroups drops unshown faces and empty groups, biggest '
        'first', () {
      final at = DateTime(2024);
      AssetRecord record(String id, {bool hidden = false}) => AssetRecord(
        localId: id,
        contentHash: id,
        platform: 'ios',
        createdAt: at,
        updatedAt: at,
        isHidden: hidden,
      );
      final shown = shownFaceGroups(
        [
          StoredFaceGroup(id: 'small', faces: [(localId: 'a', face: vision)]),
          StoredFaceGroup(
            id: 'big',
            faces: [(localId: 'a', face: other), (localId: 'b', face: vision)],
          ),
          StoredFaceGroup(id: 'hidden', faces: [(localId: 'h', face: vision)]),
        ],
        {'a': record('a'), 'b': record('b'), 'h': record('h', hidden: true)},
      );
      expect(shown.map((g) => g.id), ['big', 'small']);
    });

    group('store', () {
      setUpAll(sqfliteFfiInit);

      AiAnalysisStore newStore() {
        final store = AiAnalysisStore(
          databaseFactory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        );
        addTearDown(store.close);
        return store;
      }

      Future<void> put(
        AiAnalysisStore store,
        List<GroupedFace> faces, {
        Map<String, String?> groups = const {},
      }) => store.importNamedFaces(
        const [],
        grouped: faces,
        groups: groups,
        added: {
          for (final f in faces) f.localId: [f.face],
        },
      );

      test('groups faces; the same file again changes nothing', () async {
        final store = newStore();
        final file = <GroupedFace>[
          (localId: 'p', face: vision, groupId: 'g1'),
          (localId: 'q', face: vision, groupId: 'g1'),
          (localId: 'r', face: vision, groupId: 'g2'),
        ];
        await put(store, file, groups: {'g1': 'Ava'});
        var groups = await store.faceGroups();
        expect(groups.map((g) => (g.id, g.suggest, g.faces.length)).toSet(), {
          ('g1', 'Ava', 2),
          ('g2', null, 1),
        });
        expect(await store.facesFor('p'), [vision]);

        await store.ungroupFaces([(localId: 'q', face: vision)]);
        await store.dismissGroup('g2');
        await put(store, file, groups: {'g1': 'Ava'});
        groups = await store.faceGroups();
        expect(groups.single.id, 'g1');
        expect(groups.single.faces.single.localId, 'p');

        // A newer run takes faces out of a deleted group, or one they were
        // taken out of.
        await put(store, [
          (localId: 'q', face: vision, groupId: 'g3'),
          (localId: 'r', face: vision, groupId: 'g3'),
        ]);
        final g3 = (await store.faceGroups()).singleWhere((g) => g.id == 'g3');
        expect(g3.faces.map((f) => f.localId).toSet(), {'q', 'r'});
      });

      test('a named face is never grouped', () async {
        final store = newStore();
        await store.importNamedFaces(
          [(localId: 'p', face: vision, personId: 'alice')],
          added: {
            'p': [vision],
          },
        );
        await put(store, [(localId: 'p', face: vision, groupId: 'g1')]);
        expect(await store.faceGroups(), isEmpty);
      });

      test('hiding a photo drops its group rows', () async {
        final store = newStore();
        await put(store, [
          (localId: 'p', face: vision, groupId: 'g1'),
          (localId: 'q', face: vision, groupId: 'g1'),
        ]);
        await store.forgetFacesOf(['p']);
        final g = (await store.faceGroups()).single;
        expect(g.faces.map((f) => f.localId), ['q']);
        await store.forgetAssets(['q']);
        expect(await store.faceGroups(), isEmpty);
      });
    });

    test('naming a group links the ticked faces; the rest stay', () async {
      final records = FakeAssetRecordStore();
      final analysis = FakeAiAnalysisStore();
      final people = FakePersonStore();
      final ava = await people.create(name: 'Ava');
      for (final id in ['p1', 'p2', 'p3']) {
        await records.upsert(
          localId: id,
          contentHash: id,
          platform: 'ios',
          createdAt: DateTime(2024, 6),
        );
      }
      await analysis.importNamedFaces(
        const [],
        grouped: [
          for (final id in ['p1', 'p2', 'p3'])
            (localId: id, face: vision, groupId: 'g'),
        ],
        added: {
          for (final id in ['p1', 'p2', 'p3']) id: [vision],
        },
      );
      final import = FaceImport(
        personStore: people,
        assetRecordStore: records,
        analysisStore: analysis,
      );
      final named = await import.name(ava.id, [
        (localId: 'p1', face: vision),
        (localId: 'p2', face: vision),
      ]);
      expect(named, hasLength(2));
      expect(await analysis.namedFacesIn('p1'), {vision: ava.id});
      expect((await people.allMemberships())[ava.id], ['p1', 'p2']);
      final left = (await analysis.faceGroups()).single;
      expect(left.faces.single.localId, 'p3');

      await import.unname(ava.id, 'g', named);
      expect(await analysis.namedFacesIn('p1'), isEmpty);
      expect((await people.allMemberships())[ava.id] ?? const [], isEmpty);
      expect((await analysis.faceGroups()).single.faces, hasLength(3));
    });
  });
}

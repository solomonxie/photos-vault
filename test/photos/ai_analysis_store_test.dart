import 'dart:io';

import 'package:photos_vault/photos/ai_analysis.dart';
import 'package:photos_vault/photos/ai_analysis_store.dart';

import 'package:photos_vault/photos/person.dart' show FaceRect;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  AiAnalysisStore newStore() {
    final store = AiAnalysisStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return store;
  }

  test('namedFacesIn lists only the faces given a name', () async {
    final store = newStore();
    const named = FaceRect(0.1, 0.1, 0.2, 0.2);
    await store.nameFaces([(localId: 'p', face: named)], 'nina');
    expect(await store.namedFacesIn('p'), {named: 'nina'});
  });

  group('face descriptors', () {
    const face = FaceRect(0.3, 0.3, 0.4, 0.4);

    test('bounded reads return only the photos asked for', () async {
      final store = newStore();
      for (final id in ['a', 'b', 'c']) {
        await store.saveFaceCount(
          localId: id,
          peopleCount: 2,
          analyzedAt: DateTime(2026),
          faces: const [face, FaceRect(0.1, 0.1, 0.1, 0.1)],
        );
        if (id == 'b') {
          await store.nameFaces([(localId: id, face: face)], 'nina');
        }
      }

      expect(await store.faceCounts(), {'a': 2, 'b': 2, 'c': 2});
      expect((await store.facesOf(['a', 'x'])).keys, ['a']);
      expect((await store.namedFacesOf(['a', 'b'])).keys, ['b']);
    });

    test('face counts are read again after a write', () async {
      final store = newStore();
      final before = store.revision;
      await store.saveFaceCount(
        localId: 'a',
        peopleCount: 1,
        analyzedAt: DateTime(2026),
        faces: const [face],
      );
      expect(store.revision, greaterThan(before));
      expect(await store.faceCounts(), {'a': 1});

      await store.forgetFacesOf(['a']);

      expect(await store.faceCounts(), isEmpty);
    });

    test('deleting a person unnames their faces', () async {
      final store = newStore();
      await store.nameFaces([(localId: 'p1', face: face)], 'nina');

      await store.forgetPerson('nina');

      expect(await store.facesOfPerson('nina'), isEmpty);
      expect(await store.namedFacesIn('p1'), isEmpty);
    });

    Future<AiAnalysisStore> described() async {
      final store = newStore();
      for (final id in ['hidden', 'kept']) {
        await store.saveFaceCount(
          localId: id,
          peopleCount: 1,
          analyzedAt: DateTime(2026),
          faces: const [face],
        );
        await store.nameFaces([(localId: id, face: face)], 'nina');
      }
      return store;
    }

    test('hiding a photo drops its faces and names', () async {
      final store = await described();

      await store.forgetFacesOf(['hidden']);

      expect(await store.facesFor('hidden'), isEmpty);
      expect(await store.faceOfPersonIn('hidden', 'nina'), isNull);
      expect(await store.faceOfPersonIn('kept', 'nina'), face);
      expect((await store.facesByAsset()).keys, ['kept']);
      expect(await store.get('hidden'), isNotNull, reason: 'the row stays');
    });

    test('a permanent delete drops every row of the photo', () async {
      final store = await described();

      await store.forgetAssets(['hidden']);

      expect(await store.get('hidden'), isNull);
      expect(await store.faceOfPersonIn('hidden', 'nina'), isNull);
      expect(await store.get('kept'), isNotNull);
    });
  });

  test('facesFor reads back the boxes a scan stored', () async {
    final store = newStore();
    await store.saveFaceCount(
      localId: 'p1',
      peopleCount: 2,
      analyzedAt: DateTime(2024),
      faces: const [FaceRect(0.1, 0.2, 0.3, 0.4), FaceRect(0.5, 0.5, 0.1, 0.1)],
    );

    expect(await store.facesFor('p1'), const [
      FaceRect(0.1, 0.2, 0.3, 0.4),
      FaceRect(0.5, 0.5, 0.1, 0.1),
    ]);
    // A photo nothing has looked at yet, and one scanned before the boxes
    // were kept — neither has faces to show, and neither is an error.
    expect(await store.facesFor('never-scanned'), isEmpty);
  });

  test('save then listAll round-trips one analysis', () async {
    final store = newStore();
    final analysis = AiPhotoAnalysis(
      localId: 'p1',
      peopleCount: 2,
      analyzedAt: DateTime(2024),
    );

    await store.save(analysis);

    final all = await store.listAll();
    expect(all, hasLength(1));
    expect(all['p1']!.peopleCount, 2);
  });

  test('save overwrites a prior analysis for the same localId', () async {
    final store = newStore();
    await store.save(
      AiPhotoAnalysis(
        localId: 'p1',
        peopleCount: 1,
        analyzedAt: DateTime(2024),
      ),
    );

    await store.save(
      AiPhotoAnalysis(
        localId: 'p1',
        peopleCount: 3,
        analyzedAt: DateTime(2024),
      ),
    );

    final all = await store.listAll();
    expect(all, hasLength(1));
    expect(all['p1']!.peopleCount, 3);
  });

  test('listAll is empty with nothing saved', () async {
    final store = newStore();

    expect(await store.listAll(), isEmpty);
  });

  group('WP12: faces keep their names', () {
    const face = FaceRect(0.1, 0.2, 0.3, 0.4);

    test('turning boxes upright moves names with them (05#7)', () async {
      final dir = Directory.systemTemp.createTempSync('ai_upright_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/ai.db';
      final store = AiAnalysisStore(
        databaseFactory: databaseFactoryFfi,
        path: path,
      );
      addTearDown(store.close);
      await store.saveFaceCount(
        localId: 'p',
        peopleCount: 1,
        analyzedAt: DateTime(2026),
        faces: const [face],
      );
      // As a pre-v7 row: measured on the raw buffer.
      final db = await databaseFactoryFfi.openDatabase(path);
      await db.update('ai_analysis', {'upright': 0});
      await store.nameFaces([(localId: 'p', face: face)], 'nina');
      expect((await store.get('p'))!.legacyBoxes, isTrue);

      await store.reorientFaces('p', 6);
      await store.reorientFaces('p', 6);

      final upright = face.oriented(6);
      expect(await store.facesFor('p'), [upright], reason: 'once only');
      expect(await store.faceOfPersonIn('p', 'nina'), upright);
      expect((await store.get('p'))!.legacyBoxes, isFalse);
    });

    test('finding faces again carries names to the boxes they overlap, and '
        'drops unnamed leftovers (05#23)', () async {
      final store = newStore();
      await store.nameFaces([(localId: 'p', face: face)], 'nina');
      const shifted = FaceRect(0.11, 0.21, 0.3, 0.39);

      await store.saveFaceCount(
        localId: 'p',
        peopleCount: 1,
        analyzedAt: DateTime(2026),
        faces: const [shifted],
      );

      expect(await store.faceOfPersonIn('p', 'nina'), shifted);
      expect(await store.namedFacesIn('p'), {shifted: 'nina'});
    });
  });
}

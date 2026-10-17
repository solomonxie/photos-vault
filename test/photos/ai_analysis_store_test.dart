import 'dart:io';

import 'package:photos_vault/photos/ai_analysis.dart';
import 'package:photos_vault/photos/ai_analysis_store.dart';

import 'dart:typed_data';

import 'package:photos_vault/photos/on_device_vision.dart';
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

  group('face descriptors', () {
    final nina = FaceDescriptor(
      vector: Float32List.fromList(const [0, 0, 1]),
      revision: 1,
    );
    const face = FaceRect(0.3, 0.3, 0.4, 0.4);

    test('a confirmed face round-trips and is comparable again', () async {
      final store = newStore();
      await store.saveDescriptor(
        localId: 'p1',
        face: face,
        personId: 'nina',
        descriptor: nina,
      );

      final confirmed = await store.confirmedFaces();
      expect(confirmed.single.personId, 'nina');
      expect(confirmed.single.descriptor.distanceTo(nina), 0);
      expect(await store.hasDescriptorsFor('nina'), isTrue);
      expect(await store.hasDescriptorsFor('sam'), isFalse);
    });

    test('keeps only the newest few per person', () async {
      final store = newStore();
      for (var i = 0; i < 5; i++) {
        await store.saveDescriptor(
          localId: 'p$i',
          face: face,
          personId: 'nina',
          descriptor: nina,
        );
      }

      // Matching is a scan; the twentieth photo of somebody adds far less
      // than the second.
      expect(await store.confirmedFaces(perPerson: 2), hasLength(2));
    });

    test('newest confirmation first, capped per person', () async {
      final store = newStore();
      for (final (id, person) in const [
        ('p0', 'nina'),
        ('p1', 'sam'),
        ('p2', 'nina'),
        ('p3', 'nina'),
      ]) {
        await store.saveDescriptor(
          localId: id,
          face: face,
          personId: person,
          descriptor: nina,
        );
        await Future<void>.delayed(const Duration(milliseconds: 3));
      }

      final confirmed = await store.confirmedFaces(perPerson: 2);

      expect(confirmed.map((f) => f.localId), ['p3', 'p2', 'p1']);
      expect(confirmed.first.descriptor.distanceTo(nina), 0);
    });

    test('bounded reads return only the photos asked for', () async {
      final store = newStore();
      for (final id in ['a', 'b', 'c']) {
        await store.saveFaceCount(
          localId: id,
          peopleCount: 2,
          analyzedAt: DateTime(2026),
          faces: const [face, FaceRect(0.1, 0.1, 0.1, 0.1)],
        );
        await store.saveDescriptor(
          localId: id,
          face: face,
          personId: id == 'b' ? 'nina' : null,
          descriptor: nina,
        );
        await store.saveSuggestions(id, {face.encode(): 'nina'});
      }

      expect(await store.faceCounts(), {'a': 2, 'b': 2, 'c': 2});
      expect((await store.facesOf(['a', 'x'])).keys, ['a']);
      expect((await store.suggestionsOf(['b'])).keys, ['b']);
      // Named faces are references, not strangers.
      expect((await store.unnamedDescriptorsOf(['a', 'b'])).keys, [
        AiAnalysisStore.faceKey('a', face),
      ]);
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

    test('an empty descriptor is not stored', () async {
      final store = newStore();
      await store.saveDescriptor(
        localId: 'p1',
        face: face,
        personId: 'nina',
        descriptor: FaceDescriptor(vector: Float32List(0), revision: 1),
      );
      expect(await store.confirmedFaces(), isEmpty);
    });

    test(
      'deleting a person unnames their faces, keeping the descriptions',
      () async {
        final store = newStore();
        await store.saveDescriptor(
          localId: 'p1',
          face: face,
          personId: 'nina',
          descriptor: nina,
        );
        await store.saveSuggestions('p2', {face.encode(): 'nina'});

        await store.forgetPerson('nina');

        expect(await store.confirmedFaces(), isEmpty);
        expect(await store.suggestionsByAsset(), isEmpty);
        // The description stays, unnamed: it costs a Vision pass to make
        // and it was never wrong — only the name on it was.
        final left = await store.allDescribedFaces();
        expect(left.single.localId, 'p1');
        expect(left.single.personId, isNull);
      },
    );

    test('"looked, no opinion" counts as looked', () async {
      final store = newStore();
      await store.saveSuggestions('p1', {face.encode(): null});

      // Not a guess, so nothing to show…
      expect(await store.suggestionsFor('p1'), isEmpty);
      expect(await store.suggestionsByAsset(), isEmpty);
      // …but recorded, or the analyze pass asks the same unanswerable
      // question of this photo forever.
      expect(await store.matchedAssets(), {'p1'});
    });

    test('clearing reopens the question, for one photo or all', () async {
      final store = newStore();
      await store.saveSuggestions('p1', {face.encode(): 'nina'});
      await store.saveSuggestions('p2', {face.encode(): null});

      await store.clearSuggestions('p1');
      expect(await store.matchedAssets(), {'p2'});

      await store.clearAllSuggestions();
      expect(await store.matchedAssets(), isEmpty);
    });

    test('confirmedFacesFor is one person\'s faces only', () async {
      final store = newStore();
      await store.saveDescriptor(
        localId: 'p1',
        face: face,
        personId: 'nina',
        descriptor: nina,
      );
      await store.saveDescriptor(
        localId: 'p2',
        face: face,
        personId: 'sam',
        descriptor: nina,
      );
      await store.saveDescriptor(localId: 'p3', face: face, descriptor: nina);

      final faces = await store.confirmedFacesFor('nina');
      expect(faces.map((f) => f.localId), ['p1']);
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
        await store.saveDescriptor(
          localId: id,
          face: face,
          personId: 'nina',
          descriptor: nina,
        );
        await store.saveSuggestions(id, {face.encode(): 'nina'});
      }
      return store;
    }

    test('hiding a photo drops its faces, vectors and guesses', () async {
      final store = await described();

      await store.forgetFacesOf(['hidden']);

      expect(await store.facesFor('hidden'), isEmpty);
      expect(await store.descriptorFor('hidden', face), isNull);
      expect(await store.suggestionsFor('hidden'), isEmpty);
      expect((await store.allDescribedFaces()).map((f) => f.localId), ['kept']);
      expect((await store.facesByAsset()).keys, ['kept']);
      expect(await store.get('hidden'), isNotNull, reason: 'paid half stays');
    });

    test('a permanent delete drops every row of the photo', () async {
      final store = await described();

      await store.forgetAssets(['hidden']);

      expect(await store.get('hidden'), isNull);
      expect(await store.descriptorFor('hidden', face), isNull);
      expect(await store.matchedAssets(), {'kept'});
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
    FaceDescriptor print(int pipeline, List<double> v) => FaceDescriptor(
      vector: Float32List.fromList(v),
      revision: FaceDescriptor.combineRevision(1, pipeline),
    );
    const face = FaceRect(0.1, 0.2, 0.3, 0.4);

    test('a re-description replaces the vector, not the name (05#4)', () async {
      final store = newStore();
      await store.saveDescriptor(
        localId: 'p',
        face: face,
        personId: 'nina',
        descriptor: print(3, const [1, 0]),
      );

      await store.saveDescriptor(
        localId: 'p',
        face: face,
        descriptor: print(4, const [0, 1]),
      );

      final named = await store.confirmedFacesFor('nina');
      expect(named.single.descriptor.pipeline, 4);
      expect(await store.faceOfPersonIn('p', 'nina'), face);
      expect(
        await store.staleDescriptorAssets(FaceDescriptor.livePipelines),
        isEmpty,
      );
    });

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
      await store.saveDescriptor(
        localId: 'p',
        face: face,
        personId: 'nina',
        descriptor: print(4, const [1, 0]),
      );
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
      const gone = FaceRect(0.7, 0.7, 0.1, 0.1);
      await store.saveDescriptor(
        localId: 'p',
        face: face,
        personId: 'nina',
        descriptor: print(4, const [1, 0]),
      );
      await store.saveDescriptor(
        localId: 'p',
        face: gone,
        descriptor: print(4, const [0, 1]),
      );
      const shifted = FaceRect(0.11, 0.21, 0.3, 0.39);

      await store.saveFaceCount(
        localId: 'p',
        peopleCount: 1,
        analyzedAt: DateTime(2026),
        faces: const [shifted],
      );

      expect(await store.faceOfPersonIn('p', 'nina'), shifted);
      final all = await store.allDescribedFaces();
      expect(all.map((f) => f.face), [shifted], reason: 'no duplicate');
    });
  });
}

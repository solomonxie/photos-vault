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
      eventLabel: 'Birthday party',
      analyzedAt: DateTime(2024),
    );

    await store.save(analysis);

    final all = await store.listAll();
    expect(all, hasLength(1));
    expect(all['p1']!.peopleCount, 2);
    expect(all['p1']!.eventLabel, 'Birthday party');
  });

  test('save overwrites a prior analysis for the same localId', () async {
    final store = newStore();
    await store.save(
      AiPhotoAnalysis(
        localId: 'p1',
        peopleCount: 1,
        eventLabel: 'A',
        analyzedAt: DateTime(2024),
      ),
    );

    await store.save(
      AiPhotoAnalysis(
        localId: 'p1',
        peopleCount: 3,
        eventLabel: 'B',
        analyzedAt: DateTime(2024),
      ),
    );

    final all = await store.listAll();
    expect(all, hasLength(1));
    expect(all['p1']!.peopleCount, 3);
    expect(all['p1']!.eventLabel, 'B');
  });

  test('listAll is empty with nothing saved', () async {
    final store = newStore();

    expect(await store.listAll(), isEmpty);
  });
}

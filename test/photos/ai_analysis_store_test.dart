import 'package:bring_your_own_photos/photos/ai_analysis.dart';
import 'package:bring_your_own_photos/photos/ai_analysis_store.dart';
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

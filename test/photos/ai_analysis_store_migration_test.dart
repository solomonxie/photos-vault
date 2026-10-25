import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/ai_analysis.dart';
import 'package:photos_vault/photos/ai_analysis_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The schema as it shipped at v5 — with `event_label`, the occasion guess
/// behind a collection albums already did better.
Future<void> _seedV5(String path) async {
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 5,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE ai_analysis (
          local_id TEXT PRIMARY KEY,
          people_count INTEGER NOT NULL,
          event_label TEXT NOT NULL,
          analyzed_at INTEGER NOT NULL,
          tags TEXT NOT NULL DEFAULT '',
          description TEXT NOT NULL DEFAULT '',
          reviewed INTEGER NOT NULL DEFAULT 0,
          faces TEXT NOT NULL DEFAULT ''
        )
      '''),
    ),
  );
  await db.insert('ai_analysis', {
    'local_id': 'manual:a',
    'people_count': 2,
    'event_label': "Nina's Wedding",
    'analyzed_at': DateTime.utc(2024).millisecondsSinceEpoch,
    'tags': '["cake"]',
    'description': 'Two of them cutting the cake.',
    'reviewed': 0,
    'faces': '0.1,0.1,0.2,0.2',
  });
  await db.close();
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ai_analysis_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('dropping event_label keeps everything else in the row', () async {
    final path = p.join(dir.path, 'ai_analysis.db');
    await _seedV5(path);

    final store = AiAnalysisStore(
      databaseFactory: databaseFactoryFfi,
      path: path,
    );
    addTearDown(store.close);

    final found = (await store.listAll())['manual:a']!;
    expect(found.peopleCount, 2);
    expect(await store.facesFor('manual:a'), hasLength(1));

    // And the column is gone, so a write that doesn't name it still lands.
    await store.save(
      AiPhotoAnalysis(
        localId: 'manual:b',
        peopleCount: 1,
        analyzedAt: DateTime.utc(2024),
      ),
    );
    expect(await store.listAll(), hasLength(2));
  });

  test('boxes from before v7 are marked to be turned upright', () async {
    final path = p.join(dir.path, 'ai_analysis.db');
    await _seedV5(path);
    final store = AiAnalysisStore(
      databaseFactory: databaseFactoryFfi,
      path: path,
    );
    addTearDown(store.close);

    expect((await store.get('manual:a'))!.legacyBoxes, isTrue);
    await store.saveFaceCount(
      localId: 'manual:b',
      peopleCount: 0,
      analyzedAt: DateTime(2026),
    );
    expect((await store.get('manual:b'))!.legacyBoxes, isFalse);
  });

  test('v8 indexes the per-person reads', () async {
    final path = p.join(dir.path, 'ai_analysis.db');
    await _seedV5(path);
    final store = AiAnalysisStore(
      databaseFactory: databaseFactoryFfi,
      path: path,
    );
    await store.listAll();
    await store.close();

    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(db.close);
    Future<String> plan(String sql, [List<Object?> args = const []]) async =>
        (await db.rawQuery(
          'EXPLAIN QUERY PLAN $sql',
          args,
        )).map((r) => r['detail']).join('\n');

    expect(await db.getVersion(), 8);
    final indexes = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND name NOT LIKE 'sqlite_%'",
    );
    expect(indexes.map((r) => r['name']), {
      'face_descriptor_person',
      'face_suggestion_person',
      'face_group_member_group',
    });
    expect(
      await plan(
        'SELECT * FROM face_descriptor WHERE person_id = ? '
        'ORDER BY confirmed_at DESC LIMIT 40',
        ['nina'],
      ),
      allOf(contains('face_descriptor_person'), isNot(contains('TEMP'))),
    );
    // The order pass reads the index alone; vectors never ride the sort.
    expect(
      await plan(
        'SELECT rowid AS id, person_id FROM face_descriptor '
        'WHERE person_id IS NOT NULL ORDER BY confirmed_at DESC',
      ),
      contains('COVERING INDEX face_descriptor_person'),
    );
    expect(
      await plan('DELETE FROM face_suggestion WHERE person_id = ?', ['nina']),
      contains('face_suggestion_person'),
    );
  });
}

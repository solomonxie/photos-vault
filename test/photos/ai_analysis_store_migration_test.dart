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
    expect(found.tags, ['cake']);
    expect(found.description, 'Two of them cutting the cake.');
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
}

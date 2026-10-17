import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/ai_analysis_store.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Counts opens; everything else is the real ffi factory.
class _CountingFactory implements DatabaseFactory {
  int opens = 0;

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    opens++;
    // Slow enough that a second caller arrives while the first opens.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return databaseFactoryFfi.openDatabase(path, options: options);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// PW9 DB-16: concurrent first callers share one open.
void main() {
  setUpAll(sqfliteFfiInit);

  test('the people store opens once for concurrent first callers', () async {
    final factory = _CountingFactory();
    final store = PersonStore(
      databaseFactory: factory,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    await Future.wait([store.listAll(), store.listAll(), store.listAll()]);
    expect(factory.opens, 1);
  });

  test('the analysis store opens once, and a reopen moves its revision '
      '(the file may have been replaced)', () async {
    final factory = _CountingFactory();
    final store = AiAnalysisStore(
      databaseFactory: factory,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    await Future.wait([store.listAll(), store.listAll(), store.listAll()]);
    expect(factory.opens, 1);

    final before = store.revision;
    await store.close();
    expect(store.revision, isNot(before));
    final closed = store.revision;
    await store.listAll();
    expect(factory.opens, 2);
    expect(store.revision, isNot(closed));
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/upload/sync_job.dart';
import 'package:photos_vault/upload/sync_job_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test('a hidden photo is claimed before a newer library photo', () async {
    final store = SyncJobStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    await store.enqueue(
      localId: 'library',
      kind: SyncJobKind.uploadOriginal,
      displayName: 'library',
      assetCreatedAt: DateTime(2026, 10, 5),
    );
    await store.enqueue(
      localId: 'hidden',
      kind: SyncJobKind.uploadOriginal,
      displayName: 'hidden',
      assetCreatedAt: DateTime(2020),
      priority: 1,
    );
    expect((await store.dequeueNextPending())?.localId, 'hidden');
    expect((await store.dequeueNextPending())?.localId, 'library');
    await store.close();
  });
}

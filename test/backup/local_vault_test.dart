import 'dart:io';

import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/backup/local_vault.dart';
import 'package:photos_vault/backup/snapshot_archive.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_album_store.dart';
import '../support/fake_person_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory documents;
  late Directory support;

  setUp(() {
    documents = Directory.systemTemp.createTempSync('vault-documents');
    support = Directory.systemTemp.createTempSync('vault-support');
    addTearDown(() {
      documents.deleteSync(recursive: true);
      support.deleteSync(recursive: true);
    });
  });

  ({AssetRecordStore store, LocalVault vault}) newVault({
    DateTime Function()? now,
  }) {
    final store = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return (
      store: store,
      vault: LocalVault(
        settings: store,
        snapshots: AppSnapshotIo(
          assetRecordStore: store,
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
        ),
        documentsDirectory: () async => documents,
        supportDirectory: () async => support,
        now: now,
      ),
    );
  }

  List<String> namesIn(Directory directory) =>
      directory.listSync().map((entity) => p.basename(entity.path)).toList()
        ..sort();

  test('the daily copy lands in the Files-visible folder', () async {
    final (:store, :vault) = newVault();
    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');

    expect(await vault.keepDailyCopy(), isTrue);

    expect(namesIn(documents), [LocalVault.dailyFileName]);
    final snapshot = unzipSnapshot(
      File(p.join(documents.path, LocalVault.dailyFileName)).readAsBytesSync(),
    );
    expect(snapshot!.assets.single['localId'], 'a');
  });

  test('a second copy the same day is not taken', () async {
    final (:store, :vault) = newVault();
    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');
    await vault.keepDailyCopy();

    await store.setDescription('a', 'changed again');

    expect(await vault.keepDailyCopy(), isFalse);
  });

  test('a new day with nothing changed is not copied either', () async {
    var today = DateTime(2026, 9, 18, 21);
    final (:store, :vault) = newVault(now: () => today);
    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');
    await vault.keepDailyCopy();

    today = DateTime(2026, 9, 19, 21);

    expect(await vault.keepDailyCopy(), isFalse);
  });

  test('a new day with a change is', () async {
    var today = DateTime(2026, 9, 18, 21);
    final (:store, :vault) = newVault(now: () => today);
    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');
    await vault.keepDailyCopy();

    today = DateTime(2026, 9, 19, 21);
    await store.setDescription('a', 'a day at the beach');

    expect(await vault.keepDailyCopy(), isTrue);
  });

  test('a big operation gets a file the daily overwrite cannot eat', () async {
    final (:store, :vault) = newVault(now: () => DateTime(2026, 9, 18, 14, 32));
    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');

    await vault.keepDailyCopy();
    await vault.guard('restore');

    expect(namesIn(documents), [
      '20260918-143200-before-restore-photos-vault.zip',
      LocalVault.dailyFileName,
    ]);
  });

  test('the copy before a deletion says so in its name', () async {
    final (:store, :vault) = newVault(now: () => DateTime(2026, 9, 18, 14, 32));
    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');

    await vault.guardBeforeDeletion();

    // The one file somebody goes looking for by name after wiping the app,
    // and it holds the library as it stood a moment before.
    expect(namesIn(documents), [
      '20260918-143200-pre-deletion-photos-vault.zip',
    ]);
    final snapshot = unzipSnapshot(
      File(
        p.join(documents.path, '20260918-143200-pre-deletion-photos-vault.zip'),
      ).readAsBytesSync(),
    );
    expect(snapshot!.assets.single['localId'], 'a');
  });

  test('a pre-deletion copy outlives the week-old rule', () async {
    final (:store, :vault) = newVault();
    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');

    final ancient = File(
      p.join(documents.path, LocalVault.preDeletionName(DateTime(2026, 1, 1))),
    )..writeAsBytesSync(const [1, 2, 3]);
    ancient.setLastModifiedSync(
      DateTime.now().subtract(const Duration(days: 400)),
    );

    await vault.prune();

    // The copy somebody comes back for is the one they come back for
    // late. Age is the wrong rule for it.
    expect(
      namesIn(documents),
      contains('20260101-000000-pre-deletion-photos-vault.zip'),
    );
  });

  test('only the newest few pre-deletion copies are kept', () async {
    final (:store, :vault) = newVault();
    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');

    for (var day = 1; day <= 5; day++) {
      File(
        p.join(
          documents.path,
          LocalVault.preDeletionName(DateTime(2026, 1, day)),
        ),
      ).writeAsBytesSync(const [1, 2, 3]);
    }

    await vault.prune();

    expect(
      namesIn(documents),
      unorderedEquals([
        '20260103-000000-pre-deletion-photos-vault.zip',
        '20260104-000000-pre-deletion-photos-vault.zip',
        '20260105-000000-pre-deletion-photos-vault.zip',
      ]),
    );
  });

  test('a copy named by the build before this one is still found', () async {
    final (:store, :vault) = newVault();
    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');

    // What shipped before the rename, sitting in somebody's Files folder.
    final legacy = File(
      p.join(documents.path, 'photos-vault-before-import-20260101-000000.zip'),
    )..writeAsBytesSync(const [1, 2, 3]);
    legacy.setLastModifiedSync(
      DateTime.now().subtract(const Duration(days: 8)),
    );

    await vault.prune();

    expect(namesIn(documents), isEmpty);
  });

  test('copies older than a week go, the rest stay', () async {
    final (:store, :vault) = newVault();
    await store.upsert(localId: 'a', contentHash: 'h', platform: 'ios');

    final old = File(
      p.join(
        documents.path,
        LocalVault.guardName('import', DateTime(2026, 1, 1)),
      ),
    )..writeAsBytesSync(const [1, 2, 3]);
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 8)));
    final recent = File(
      p.join(
        documents.path,
        LocalVault.guardName('import', DateTime(2026, 9, 20)),
      ),
    )..writeAsBytesSync(const [1, 2, 3]);
    recent.setLastModifiedSync(
      DateTime.now().subtract(const Duration(days: 2)),
    );
    // Not ours: the folder is the user's, and pruning only touches names
    // this app wrote.
    final theirs = File(p.join(documents.path, 'holiday.zip'))
      ..writeAsBytesSync(const [1, 2, 3]);
    theirs.setLastModifiedSync(
      DateTime.now().subtract(const Duration(days: 400)),
    );

    await vault.prune();

    expect(
      namesIn(documents),
      unorderedEquals([
        '20260920-000000-before-import-photos-vault.zip',
        'holiday.zip',
      ]),
    );
  });
}

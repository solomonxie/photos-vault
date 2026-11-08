import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/asset_removal.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/viewer/person_deletion.dart';

import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';
import '../settings/fake_secure_store.dart';

void main() {
  late FakePersonStore people;
  late FakeAssetRecordStore records;
  late String mia;

  setUp(() async {
    people = FakePersonStore();
    records = FakeAssetRecordStore();
    mia = (await people.create(name: 'Mia')).id;
    final bob = (await people.create(name: 'Bob')).id;
    for (final id in [
      'manual:alone',
      'manual:both',
      'manual:hidden',
      'manual:linked',
    ]) {
      await records.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        sourceType: AssetSourceType.manualFile,
        sourcePath: '/tmp/$id.jpg',
        // Kept on her page; the linked one is in the main library.
        isArchived: id != 'manual:linked',
        peopleOnly: id != 'manual:linked',
      );
    }
    await people.addAssets(mia, [
      'manual:alone',
      'manual:both',
      'manual:linked',
    ]);
    await people.addAssets(bob, ['manual:both']);
    await records.setPasscodeHash(
      'manual:hidden',
      hashPasscode(personAlbumCode(mia, '0420')),
    );
  });

  PersonDeletion deletion({required bool folderGoes}) => PersonDeletion(
    personStore: people,
    assetRecordStore: records,
    removal: AssetRemoval(
      store: records,
      targetsStore: BackupTargetsStore(store: FakeSecureStore()),
    ),
    deleteFolder: (tag, code) async => folderGoes,
  );

  test('their own library and every hidden folder, not a shared or linked '
      'photo', () async {
    final plan = await deletion(folderGoes: true).plan({mia});
    expect([for (final r in plan.photos) r.localId], ['manual:alone']);
    expect(plan.folders[mia]!.values.single, personAlbumCode(mia, '0420'));
    expect(plan.hiddenCount, 1);
  });

  test(
    'a person whose folder did not go is kept; their photos still go',
    () async {
      final keep = deletion(folderGoes: false);
      expect(await keep.run({mia}, await keep.plan({mia})), isEmpty);
      expect(await people.getById(mia), isNotNull);
      final alone = await records.getByLocalId('manual:alone');
      expect(alone == null || alone.deletedAt != null, isTrue);
      expect((await records.getByLocalId('manual:both'))!.deletedAt, isNull);

      final go = deletion(folderGoes: true);
      expect(await go.run({mia}, await go.plan({mia})), {mia});
      expect(await people.getById(mia), isNull);
    },
  );
}

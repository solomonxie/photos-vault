import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/upload/pending_deletes.dart';

import '../support/fake_asset_record_store.dart';
import '../support/scripted_deletes.dart';
import 'fake_secure_store.dart';

Future<String> _add(
  BackupTargetsStore store, {
  String key = 'AKIA1',
  String prefix = 'photos/',
}) async => (await store.add(
  accessKeyId: key,
  secretAccessKey: 'secret',
  region: 'us-east-1',
  bucket: 'my-bucket',
  prefix: prefix,
)).id;

void main() {
  test('a removed and re-added bucket runs the deletes it was owed', () async {
    final targets = BackupTargetsStore(store: FakeSecureStore());
    final records = FakeAssetRecordStore();
    final deleted = <String>[];
    final deletes = PendingDeletes(
      store: records,
      ops: ScriptedDeletes((target, key) async {
        deleted.add('${target.id}:$key');
        return true;
      }),
    );

    final id = await _add(targets);
    await deletes.add([
      PendingDelete(objectKey: 'photos/originals/plain.jpg', targetId: id),
    ]);
    await targets.remove(id);
    expect(await deletes.drain(await targets.loadAll()), 1);
    expect(deleted, isEmpty, reason: 'dormant while the bucket is gone');

    // Same bucket and folder, new credentials, written differently.
    final again = await _add(targets, key: 'AKIA2', prefix: '/photos');
    expect(again, id);
    expect(await deletes.drain(await targets.loadAll()), 0);
    expect(deleted, ['$id:photos/originals/plain.jpg']);
  });

  test(
    'a target from before derived ids keeps its id across re-adding',
    () async {
      final secure = FakeSecureStore()
        ..seed(
          'backup_targets_v1',
          jsonEncode([
            {
              'id': 'legacy-random',
              'accessKeyId': 'AKIA',
              'secretAccessKey': 'secret',
              'region': 'us-east-1',
              'bucket': 'my-bucket',
              'prefix': 'photos/',
              'provider': 's3',
            },
          ]),
        );
      final targets = BackupTargetsStore(store: secure);

      await targets.remove('legacy-random');
      expect(await _add(targets), 'legacy-random');

      // Remove All App Data clears the targets; the id still comes back.
      await targets.clearAll();
      expect(await _add(targets), 'legacy-random');
    },
  );

  test('the same bucket and folder twice is one target', () async {
    final targets = BackupTargetsStore(store: FakeSecureStore());
    final first = await _add(targets);
    final second = await _add(targets, key: 'AKIA-NEW');

    final all = await targets.loadAll();
    expect(second, first);
    expect(all, hasLength(1));
    expect(all.single.accessKeyId, 'AKIA-NEW');

    final other = await _add(targets, prefix: 'other/');
    expect(other, isNot(first));
    expect(await targets.loadAll(), hasLength(2));
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/upload/object_location.dart';

import '../settings/fake_secure_store.dart';

void main() {
  test('a key relative to the prefix is looked up under it', () async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    final target = await store.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'bucket',
      prefix: 'photos-vault/',
    );
    final asked = <String>[];

    final found = await targetHolding(
      'originals/x.jpg',
      targetsStore: store,
      get: (url, {headers}) async {
        asked.add(url.path);
        return http.Response('', 206);
      },
    );

    expect(found?.id, target.id);
    expect(asked.single, '/photos-vault/originals/x.jpg');
  });

  test('a key that already carries the prefix is not prefixed twice', () async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await store.add(
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: 'us-east-1',
      bucket: 'bucket',
      prefix: 'photos-vault/',
    );
    final asked = <String>[];

    await targetHolding(
      'photos-vault/originals/x.jpg',
      targetsStore: store,
      get: (url, {headers}) async {
        asked.add(url.path);
        return http.Response('', 206);
      },
    );

    expect(asked.single, '/photos-vault/originals/x.jpg');
  });
}

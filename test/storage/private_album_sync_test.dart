import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/private_album_sync.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  late FakeAssetRecordStore store;
  late PrivateAlbumSync sync;

  setUp(() {
    store = FakeAssetRecordStore();
    sync = PrivateAlbumSync(store);
  });

  test('an album nobody has touched is backed up', () async {
    expect(await sync.isEnabled('hash-a'), isTrue);
    expect(await sync.disabledHashes(), isEmpty);
  });

  test('turning it off, and back on again', () async {
    await sync.setEnabled('hash-a', false);
    expect(await sync.isEnabled('hash-a'), isFalse);

    await sync.setEnabled('hash-a', true);
    expect(await sync.isEnabled('hash-a'), isTrue);
    expect(await sync.disabledHashes(), isEmpty);
  });

  test('one album opting out does not decide for another', () async {
    await sync.setEnabled('hash-a', false);

    expect(await sync.isEnabled('hash-b'), isTrue);
    expect(await sync.disabledHashes(), {'hash-a'});
  });

  test('an unreadable preference falls back to backing up', () async {
    await store.setAppState('private_album_sync_off', 'not json');

    // The failure that matters is a photo silently not being backed up,
    // so a corrupt row must not be read as "everybody opted out".
    expect(await sync.isEnabled('hash-a'), isTrue);
    expect(await sync.disabledHashes(), isEmpty);
  });
}

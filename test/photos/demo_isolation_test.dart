import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/demo/demo_flag.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/storage/asset_record.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  tearDown(() => DemoFlag.active = false);

  test(
    'demo mode never reads or deletes from the real photo library',
    () async {
      DemoFlag.active = true;
      final store = FakeAssetRecordStore();
      // Default plugin calls throughout: any of them reaching photo_manager
      // would throw here, where there is no platform.
      final library = PhotoLibraryService(store: store);

      expect(await library.requestAccess(), PhotoLibraryAccess.granted);
      final result = await library.syncAll(reconcileDeletions: true);
      expect(result.isEmpty, isTrue);
      expect(await store.listAll(), isEmpty);

      final record = AssetRecord(
        localId: 'photo:x',
        contentHash: 'x',
        platform: 'ios',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        libraryId: 'REAL-ASSET-ID',
      );
      expect(await library.deleteManyFromLibrary([record]), isEmpty);
      expect(await library.entityFor(record), isNull);
    },
  );
}

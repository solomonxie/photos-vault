import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/alias_folders.dart';
import 'package:photos_vault/photos/thumbnail_cache.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/vault/hidden_transition.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/passcode_tags.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/memory_bucket.dart';

void main() {
  late FakeAssetRecordStore records;
  late VaultKeys keys;
  late Directory dir;

  Future<String> tagOf(String code) =>
      PasscodeTags(records: records, vaultKeys: keys).tagFor(code);

  Future<void> photo(String id, String tag) async {
    final file = File('${dir.path}/$id.jpg')..writeAsBytesSync([1, 2, 3]);
    await records.upsert(
      localId: id,
      contentHash: id,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: file.path,
    );
    await records.setPasscodeHash(id, tag);
  }

  AliasFolders folders() => AliasFolders(
    store: records,
    vaultKeys: keys,
    transition: HiddenTransition(
      store: records,
      loadTargets: () async => const [],
      pendingDeletes: PendingDeletes(store: records, ops: MemoryBucket()),
      analysisStore: FakeAiAnalysisStore(),
      thumbnails: ThumbnailCache(store: records),
    ),
  );

  setUp(() async {
    records = FakeAssetRecordStore();
    keys = VaultKeys(store: FakeSecureStore(), derive: deriveOnThisIsolate);
    await keys.add('a good long passphrase');
    dir = Directory.systemTemp.createTempSync('pv_alias_');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test("a merged person's folder under the same digits joins the kept "
      "one's", () async {
    final keepTag = await tagOf(personAlbumCode('keep', '1234'));
    final goneTag = await tagOf(personAlbumCode('gone', '1234'));
    await photo('mine', keepTag);
    await photo('theirs', goneTag);

    final left = await folders().fold('keep', ['gone'], '1234');

    expect(left, isEmpty);
    expect((await records.forPasscodeHash(keepTag)).map((r) => r.localId), {
      'mine',
      'theirs',
    });
    expect(await records.forPasscodeHash(goneTag), isEmpty);
  });

  test('other digits leave the alias folder alone', () async {
    final goneTag = await tagOf(personAlbumCode('gone', '1234'));
    await photo('theirs', goneTag);

    expect(await folders().fold('keep', ['gone'], '9999'), isEmpty);
    expect(await records.forPasscodeHash(goneTag), hasLength(1));
  });

  test('one that cannot move is still openable by its old code', () async {
    final goneTag = await tagOf(personAlbumCode('gone', '1234'));
    await photo('theirs', goneTag);
    await records.setLocalDeleted('theirs', true);

    expect(await folders().fold('keep', ['gone'], '1234'), [
      personAlbumCode('gone', '1234'),
    ]);
    expect(await records.forPasscodeHash(goneTag), hasLength(1));
  });
}

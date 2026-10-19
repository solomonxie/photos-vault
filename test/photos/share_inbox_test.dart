import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/manual_add.dart';
import 'package:photos_vault/photos/share_inbox.dart';
import 'package:photos_vault/vault/plain_files.dart';
import 'package:photos_vault/vault/store.dart';

import '../support/fake_asset_record_store.dart';

class _Exclusion extends BackupExclusion {
  @override
  Future<bool> exclude(String path) async => true;
}

void main() {
  late Directory root;
  late Directory inbox;
  late FakeAssetRecordStore store;
  late ShareInbox shares;
  late Map<String, String> codes;

  setUp(() {
    root = Directory.systemTemp.createTempSync('pv_share_');
    inbox = Directory(p.join(root.path, 'ShareInbox'))..createSync();
    store = FakeAssetRecordStore();
    codes = {};
    shares = ShareInbox(
      store: store,
      manualAdd: ManualAddService(
        store: store,
        targetDirectory: () async => root,
      ),
      plainFiles: PlainFiles(
        store: store,
        directory: () async => root,
        exclusion: _Exclusion(),
      ),
      inboxPath: () async => inbox.path,
      readCode: (ref) async => codes[ref],
      forgetCode: (ref) async => codes.remove(ref),
    );
  });

  void batch(String ref, String destination, List<int> bytes) {
    Directory(p.join(inbox.path, ref)).createSync();
    File(p.join(inbox.path, ref, 'a.jpg')).writeAsBytesSync(bytes);
    File(p.join(inbox.path, '$ref.json'))
        .writeAsStringSync('{"destination":"$destination"}');
  }

  Future<String> tagFor(String code) async => 'tag-$code';

  tearDown(() => root.deleteSync(recursive: true));

  void share(String name, List<int> bytes) =>
      File(p.join(inbox.path, name)).writeAsBytesSync(bytes);

  test('a half-written file is not offered', () async {
    share('a.jpg', [1, 2, 3]);
    share('b.part', [4, 5, 6]);
    expect((await shares.pending()).map((f) => p.basename(f.path)), ['a.jpg']);
  });

  test('into the library: an ordinary row, inbox emptied', () async {
    share('a.jpg', [1, 2, 3]);
    final added = await shares.file();
    expect(added, hasLength(1));
    expect(added.single.passcodeHash, isNull);
    expect(await shares.pending(), isEmpty);
  });

  test('into a hidden album: born hidden, file under vault/plain', () async {
    share('a.jpg', [1, 2, 3]);
    final added = await shares.file(passcodeHash: 'tag');
    expect(added.single.passcodeHash, 'tag');
    final row = await store.getByLocalId(added.single.localId);
    expect(
      p.isWithin(p.join(root.path, VaultStore.root, 'plain'), row!.sourcePath!),
      isTrue,
    );
    expect(await shares.pending(), isEmpty);
  });

  test('no App Group: nothing waiting', () async {
    final none = ShareInbox(store: store, inboxPath: () async => null);
    expect(await none.pending(), isEmpty);
  });
  test('a library batch is filed without asking', () async {
    batch('b1', 'library', [1, 2, 3]);
    final filed = await shares.fileBatches(tagFor: tagFor);
    expect(filed.library.single.passcodeHash, isNull);
    expect(inbox.listSync(), isEmpty);
  });

  test('a hidden batch is hidden under its code, which is forgotten', () async {
    batch('b2', 'hidden', [4, 5, 6]);
    codes['b2'] = '1234';
    final filed = await shares.fileBatches(tagFor: tagFor);
    expect(filed.hidden.single.passcodeHash, 'tag-1234');
    expect(codes, isEmpty);
    expect(inbox.listSync(), isEmpty);
  });

  test('a hidden batch without its code is asked about, not lost', () async {
    batch('b3', 'hidden', [7, 8, 9]);
    final filed = await shares.fileBatches(tagFor: tagFor);
    expect(filed.hidden, isEmpty);
    expect(await shares.pending(), hasLength(1));
  });

  test('a batch still being written is left alone', () async {
    Directory(p.join(inbox.path, 'b4')).createSync();
    File(p.join(inbox.path, 'b4', 'a.jpg')).writeAsBytesSync([1]);
    final filed = await shares.fileBatches(tagFor: tagFor);
    expect(filed.library, isEmpty);
    expect(Directory(p.join(inbox.path, 'b4')).existsSync(), isTrue);
  });
}

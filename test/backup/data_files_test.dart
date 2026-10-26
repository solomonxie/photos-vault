import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/backup/bucket_backup.dart';
import 'package:photos_vault/backup/icloud_backup.dart';
import 'package:photos_vault/backup/icloud_drive.dart';
import 'package:photos_vault/backup/data_files.dart';
import 'package:photos_vault/backup/snapshot_archive.dart';
import 'package:photos_vault/photos/conversation_file.dart';
import 'package:photos_vault/photos/conversation_store.dart';
import 'package:photos_vault/photos/words_file.dart';
import 'package:photos_vault/photos/words_store.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/settings/s3_listing.dart';
import 'package:photos_vault/upload/bucket_ops.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

ConversationMessage _m(int minute, String text) {
  final at = DateTime(2020, 1, 1, 10, minute);
  return ConversationMessage(
    chat: 'sms:1',
    source: 'sms',
    at: at,
    fromMe: false,
    sender: 'a',
    text: text,
    kind: 'text',
    hash: ConversationMessage.hashOf('sms:1', at, false, text),
  );
}

Writing _w(String id) =>
    Writing(id: id, kind: WritingKind.essay, title: id, text: 'text $id');

/// A phone's worth of stores in [dir]: chats, writings, one picture.
Future<(ConversationStore, WordsStore, Directory)> _phone(
  Directory dir, {
  bool withData = true,
}) async {
  final chats = ConversationStore(
    databaseFactory: databaseFactoryFfi,
    path: p.join(dir.path, 'conversations.db'),
  );
  final words = WordsStore(
    databaseFactory: databaseFactoryFfi,
    path: p.join(dir.path, 'words.db'),
  );
  addTearDown(chats.close);
  addTearDown(words.close);
  final support = Directory(p.join(dir.path, 'support'));
  if (withData) {
    await chats.insert('p1', [_m(1, 'hi'), _m(2, 'there')]);
    await words.insert('p1', [_w('a'), _w('b')]);
    final pic = File(p.join(support.path, 'words/media/a/1.jpg'));
    await pic.parent.create(recursive: true);
    await pic.writeAsBytes([1, 2, 3, 4]);
  } else {
    await support.create(recursive: true);
  }
  return (chats, words, support);
}

DataFiles _files(ConversationStore c, WordsStore w, Directory support) =>
    DataFiles(
      conversations: c,
      words: w,
      supportDirectory: () async => support,
    );

/// A bucket in a map, with HEADs and deletes that can be told to fail.
class _Bucket {
  final objects = <String, List<int>>{};
  bool failUploads = false;
  bool denyDeletes = false;
  bool brokenListing = false;
  final deleted = <String>[];
  final uploads = <String>[];

  Future<http.Response> put(Uri url, {Object? body}) async {
    objects[_name(url)] = body! as List<int>;
    return http.Response('', 200);
  }

  Future<http.Response> get(Uri url) async {
    final body = objects[_name(url)];
    return body == null
        ? http.Response('', 404)
        : http.Response.bytes(body, 200);
  }

  Future<bool> putFile({
    required String filePath,
    required String key,
    required S3BackupTarget target,
  }) async {
    if (failUploads) return false;
    uploads.add(key);
    objects['${target.bucket}/$key'] = await File(filePath).readAsBytes();
    return true;
  }

  Future<S3ListingResult> list({
    required S3BackupTarget target,
    String prefix = '',
    String? continuationToken,
  }) async {
    if (brokenListing) {
      return const S3ListingResult(S3ListingOutcome.networkError);
    }
    return S3ListingResult(
      S3ListingOutcome.ok,
      page: S3ListingPage(
        folders: const [],
        objects: [
          for (final key in objects.keys)
            if (key.startsWith('${target.bucket}/$prefix'))
              S3Object(
                key: key.substring(target.bucket.length + 1),
                size: objects[key]!.length,
                lastModified: DateTime(2026),
              ),
        ],
      ),
    );
  }

  static String _name(Uri url) => '${url.host.split('.').first}${url.path}';
}

class _Ops extends BucketOps {
  _Ops(this.bucket);
  final _Bucket bucket;

  @override
  Future<ObjectHead> head(S3BackupTarget target, String key) async {
    final body = bucket.objects['${target.bucket}/$key'];
    return body == null
        ? ObjectHead.absent
        : ObjectHead(Probe.present, size: body.length);
  }

  @override
  Future<bool> rawDelete(S3BackupTarget target, String key) async {
    if (bucket.denyDeletes) return false;
    bucket.deleted.add(key);
    bucket.objects.remove('${target.bucket}/$key');
    return true;
  }
}

Future<BackupTargetsStore> _targets() async {
  final store = BackupTargetsStore(store: FakeSecureStore());
  await store.add(
    accessKeyId: 'a',
    secretAccessKey: 'b',
    region: 'us-east-1',
    bucket: 'b',
    prefix: 'photos/',
  );
  return store;
}

class _Drive implements ICloudDrive {
  final archives = <String, Uint8List>{};
  final blobs = <String, List<int>>{};
  bool unreadable = false;

  @override
  Future<ICloudState> status() async => ICloudState.available;
  @override
  Future<bool> write(String name, String contents) async => true;
  @override
  Future<bool> writeBytes(String name, Uint8List bytes) async {
    archives[name] = bytes;
    return true;
  }

  @override
  Future<Uint8List?> readLatestBytes() async => null;
  @override
  Future<Uint8List?> readBytes(String name) async => archives[name];
  @override
  Future<String?> readLatest() async => null;
  @override
  Future<List<String>> list() async =>
      unreadable ? const [] : (archives.keys.toList()..sort());
  @override
  Future<bool> delete(String name) async => archives.remove(name) != null;
  @override
  Future<DateTime?> latestWriteAt() async => null;
  @override
  Future<bool> putBlob(String name, String path) async {
    blobs[name] ??= await File(path).readAsBytes();
    return true;
  }

  @override
  Future<bool> getBlob(String name, String path) async {
    final b = blobs[name];
    if (b == null) return false;
    await File(path).writeAsBytes(b);
    return true;
  }

  @override
  Future<List<String>?> listBlobs() async => blobs.keys.toList();
  @override
  Future<bool> deleteBlob(String name) async => blobs.remove(name) != null;
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('data_files');
  });
  tearDown(() => dir.delete(recursive: true));

  test('the set lists each store and picture, hashed as stored', () async {
    final (chats, words, support) = await _phone(dir);
    final set = await _files(chats, words, support).collect();
    final names = set.entries.map((e) => e.name).toSet();
    expect(names, {'conversations.db', 'words.db', 'words/media/a/1.jpg'});
    for (final e in set.entries) {
      final bytes = await File(set.files[e.sha256]!).readAsBytes();
      expect(sha256.convert(bytes).toString(), e.sha256);
      expect(bytes.length, e.bytes);
    }
    final db = set.entries.firstWhere((e) => e.kind == 'db');
    expect(db.gzip, isTrue);
    final staged = File(set.files[db.sha256]!);
    await set.dispose();
    expect(staged.existsSync(), isFalse);
    // The picture is read where it lives, never removed by the cleanup.
    expect(
      File(p.join(support.path, 'words/media/a/1.jpg')).existsSync(),
      isTrue,
    );
  });

  test('a fresh phone gets them back, merged; twice adds nothing', () async {
    final (chats, words, support) = await _phone(dir);
    final set = await _files(chats, words, support).collect();
    addTearDown(set.dispose);
    final fresh = Directory(p.join(dir.path, 'fresh'))..createSync();
    final (chats2, words2, support2) = await _phone(fresh, withData: false);
    await chats2.insert('p1', [_m(1, 'hi')]); // already here: kept
    Future<bool> fetch(String sha, String to) async {
      await File(set.files[sha]!).copy(to);
      return true;
    }

    final files = _files(chats2, words2, support2);
    expect(await files.restore(set.entries, fetch), 3);
    expect(await chats2.countFor('p1'), 2);
    expect(await words2.countFor('p1'), 2);
    expect(
      File(p.join(support2.path, 'words/media/a/1.jpg')).readAsBytesSync(),
      [1, 2, 3, 4],
    );
    await files.restore(set.entries, fetch);
    expect(await chats2.countFor('p1'), 2);
    expect(await words2.countFor('p1'), 2);
  });

  test(
    'a blob that does not match its hash is skipped, the rest restore',
    () async {
      final (chats, words, support) = await _phone(dir);
      final set = await _files(chats, words, support).collect();
      addTearDown(set.dispose);
      final fresh = Directory(p.join(dir.path, 'fresh'))..createSync();
      final (chats2, words2, support2) = await _phone(fresh, withData: false);
      final chatsSha = set.entries
          .firstWhere((e) => e.name == 'conversations.db')
          .sha256;
      final restored = await _files(chats2, words2, support2).restore(
        set.entries,
        (sha, to) async {
          if (sha == chatsSha) {
            await File(to).writeAsBytes([9, 9, 9]);
          } else {
            await File(set.files[sha]!).copy(to);
          }
          return true;
        },
      );
      expect(restored, 2);
      expect(await chats2.countFor('p1'), 0);
      expect(await words2.countFor('p1'), 2);
    },
  );

  test('an older chat database without thumbnails still merges', () async {
    final old = p.join(dir.path, 'old.db');
    final db = await databaseFactoryFfi.openDatabase(old);
    await db.execute(
      'CREATE TABLE message (person_id TEXT NOT NULL, chat TEXT NOT NULL, '
      'source TEXT NOT NULL, at INTEGER NOT NULL, from_me INTEGER NOT NULL, '
      'sender TEXT NOT NULL, text TEXT NOT NULL, kind TEXT NOT NULL, '
      'hash TEXT PRIMARY KEY)',
    );
    final m = _m(5, 'old');
    await db.insert('message', {
      'person_id': 'p9',
      'chat': m.chat,
      'source': m.source,
      'at': m.at.millisecondsSinceEpoch,
      'from_me': 0,
      'sender': m.sender,
      'text': m.text,
      'kind': m.kind,
      'hash': m.hash,
    });
    await db.close();
    final (chats, _, _) = await _phone(dir, withData: false);
    expect(await chats.mergeFrom(old), 1);
    final page = await chats.page('p9');
    expect(page.single.text, 'old');
    expect(page.single.thumb, isNull);
  });

  test('importing chats moves the backup mark', () async {
    final (chats, words, support) = await _phone(dir, withData: false);
    final io = AppSnapshotIo(
      assetRecordStore: FakeAssetRecordStore(),
      albumStore: FakeAlbumStore(),
      personStore: FakePersonStore(),
      conversationStore: chats,
      wordsStore: words,
      supportDirectory: () async => support,
    );
    final before = await io.changeMark();
    await chats.insert('p1', [_m(1, 'new')]);
    final afterChat = await io.changeMark();
    expect(afterChat, isNot(before));
    await words.insert('p1', [_w('z')]);
    expect(await io.changeMark(), isNot(afterChat));
  });

  group('bucket', () {
    Future<(BucketBackup, _Bucket, FakeAssetRecordStore)> backup({
      DateTime? now,
    }) async {
      final (chats, words, support) = await _phone(dir);
      final assets = FakeAssetRecordStore();
      final io = AppSnapshotIo(
        assetRecordStore: assets,
        albumStore: FakeAlbumStore(),
        personStore: FakePersonStore(),
        conversationStore: chats,
        wordsStore: words,
        supportDirectory: () async => support,
      );
      final bucket = _Bucket();
      return (
        BucketBackup(
          snapshots: io,
          settings: assets,
          targetsStore: await _targets(),
          put: bucket.put,
          get: bucket.get,
          list: bucket.list,
          putFile: bucket.putFile,
          ops: _Ops(bucket),
          now: now == null ? null : () => now,
        ),
        bucket,
        assets,
      );
    }

    test('blobs go up once, before the zip that lists them', () async {
      final (b, bucket, _) = await backup();
      expect(await b.backUpNow(), isTrue);
      final blobs = bucket.objects.keys
          .where((k) => k.startsWith('b/photos/app-data/blobs/'))
          .toList();
      expect(blobs, hasLength(3));
      final zip = bucket
          .objects['b/photos/app-data/${dailyArchiveName(DateTime.now())}']!;
      final listed = dataFilesIn(zip)!.map((e) => e.sha256).toSet();
      expect(blobs.map((k) => k.split('/').last).toSet(), listed);
      bucket.uploads.clear();
      expect(await b.backUpNow(), isTrue);
      expect(bucket.uploads, isEmpty);
    });

    test(
      'a blob that fails keeps the zip back and the day unrecorded',
      () async {
        final (b, bucket, _) = await backup();
        bucket.failUploads = true;
        expect(await b.backUpNow(), isFalse);
        expect(bucket.objects.keys.where((k) => k.endsWith('.zip')), isEmpty);
        expect(await b.lastBackupAt(), isNull);
      },
    );

    test('a restore brings the chats back from the bucket', () async {
      final (b, bucket, _) = await backup();
      await b.backUpNow();
      final zip = bucket
          .objects['b/photos/app-data/${dailyArchiveName(DateTime.now())}']!;
      final snapshot = unzipSnapshot(zip)!;
      expect(snapshot.dataFiles, hasLength(3));
      final fresh = Directory(p.join(dir.path, 'fresh'))..createSync();
      final (chats2, words2, support2) = await _phone(fresh, withData: false);
      final restored = await _files(
        chats2,
        words2,
        support2,
      ).restore(snapshot.dataFiles, b.fetchBlob);
      expect(restored, 3);
      expect(await chats2.countFor('p1'), 2);
    });
  });

  group('thinning', () {
    test('plan: last 30 days whole, one per older month', () {
      final today = DateTime(2026, 10, 25);
      final names = [
        '20260801.zip', '20260815.zip', '20260831.zip', // August: keep 31st
        '20260920.zip', '20260924.zip', // before the cutoff in Sept
        '20260926.zip', '20261001.zip', '20261025.zip', // within 30 days
        '202607.zip', 'index.csv', 'library.json',
        '20260101-120000-pre-deletion-photos-vault.zip',
        '20260230.zip', // not a date
      ];
      final plan = thinningPlan(names, today);
      expect(
        plan,
        unorderedEquals([
          ('20260801.zip', '20260831.zip'),
          ('20260815.zip', '20260831.zip'),
          ('20260920.zip', '20260924.zip'),
        ]),
      );
    });

    Future<(BucketBackup, _Bucket)> seeded() async {
      final (chats, words, support) = await _phone(dir, withData: false);
      final assets = FakeAssetRecordStore();
      final bucket = _Bucket();
      for (final name in [
        '20260801.zip',
        '20260815.zip',
        '20260831.zip',
        '202607.zip',
        'index.csv',
      ]) {
        bucket.objects['b/photos/app-data/$name'] = [1];
      }
      final b = BucketBackup(
        snapshots: AppSnapshotIo(
          assetRecordStore: assets,
          albumStore: FakeAlbumStore(),
          personStore: FakePersonStore(),
          conversationStore: chats,
          wordsStore: words,
          supportDirectory: () async => support,
        ),
        settings: assets,
        targetsStore: await _targets(),
        put: bucket.put,
        get: bucket.get,
        list: bucket.list,
        putFile: bucket.putFile,
        ops: _Ops(bucket),
        now: () => DateTime(2026, 10, 25),
      );
      return (b, bucket);
    }

    test(
      'after a written day, old dailies go; nothing else is touched',
      () async {
        final (b, bucket) = await seeded();
        expect(await b.backUpNow(), isTrue);
        expect(
          bucket.deleted,
          unorderedEquals([
            'photos/app-data/20260801.zip',
            'photos/app-data/20260815.zip',
          ]),
        );
        expect(
          bucket.objects.keys,
          containsAll([
            'b/photos/app-data/20260831.zip',
            'b/photos/app-data/202607.zip',
            'b/photos/app-data/index.csv',
            'b/photos/app-data/20261025.zip',
          ]),
        );
        expect(
          bucket.objects.keys.where((k) => k.contains('/blobs/')),
          isNotEmpty,
        );
      },
    );

    test('a listing that does not answer deletes nothing', () async {
      final (b, bucket) = await seeded();
      bucket.brokenListing = true;
      await b.backUpNow();
      expect(bucket.deleted, isEmpty);
    });

    test('write-only credentials stop thinning quietly', () async {
      final (b, bucket) = await seeded();
      bucket.denyDeletes = true;
      expect(await b.backUpNow(), isTrue);
      expect(bucket.deleted, isEmpty);
      expect(bucket.objects.keys, contains('b/photos/app-data/20260801.zip'));
    });

    test("a month whose keeper can't be proven keeps everything", () async {
      final (b, bucket) = await seeded();
      // The keeper goes missing between the listing and the HEAD.
      final ops = _Ops(bucket);
      final target = (await (await _targets()).loadAll()).single;
      bucket.objects.remove('b/photos/app-data/20260831.zip');
      expect(
        await ops.deleteOldArchive(
          target,
          'photos/app-data/20260801.zip',
          keeperKey: 'photos/app-data/20260831.zip',
        ),
        ArchiveDelete.refused,
      );
      expect(
        await ops.deleteOldArchive(
          target,
          'photos/app-data/blobs/abc',
          keeperKey: 'photos/app-data/20260815.zip',
        ),
        ArchiveDelete.refused,
      );
      expect(bucket.deleted, isEmpty);
      expect(b, isNotNull);
    });
  });

  group('iCloud', () {
    Future<(ICloudBackup, _Drive, ConversationStore)> icloud() async {
      final (chats, words, support) = await _phone(dir);
      final assets = FakeAssetRecordStore();
      final drive = _Drive();
      return (
        ICloudBackup(
          snapshots: AppSnapshotIo(
            assetRecordStore: assets,
            albumStore: FakeAlbumStore(),
            personStore: FakePersonStore(),
            conversationStore: chats,
            wordsStore: words,
            supportDirectory: () async => support,
          ),
          settings: assets,
          drive: drive,
        ),
        drive,
        chats,
      );
    }

    test('blobs no kept zip names are dropped', () async {
      final (backup, drive, chats) = await icloud();
      expect(await backup.backUpNow(), isTrue);
      expect(drive.blobs, hasLength(3));
      final before = drive.blobs.keys.toSet();
      // Today's zip is rewritten with the new chats; yesterday's blob for
      // them is named by nothing kept any more.
      await chats.insert('p1', [_m(9, 'later')]);
      expect(await backup.backUpNow(), isTrue);
      expect(drive.blobs, hasLength(3));
      expect(drive.blobs.keys.toSet().difference(before), hasLength(1));
    });

    test('an unreadable folder deletes no blob', () async {
      final (backup, drive, chats) = await icloud();
      await backup.backUpNow();
      await chats.insert('p1', [_m(9, 'later')]);
      drive.unreadable = true;
      await backup.backUpNow();
      expect(drive.blobs, hasLength(4));
    });
  });
}

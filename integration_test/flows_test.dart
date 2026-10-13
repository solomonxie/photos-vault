// Each multi-step flow through the real app, against a fake S3, with the
// database and the bucket checked after every step. See README.md.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photos_vault/app.dart';
import 'package:photos_vault/demo/demo_mode.dart';
import 'package:photos_vault/photos/asset_removal.dart';
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/photos/photo_library_service.dart';
import 'package:photos_vault/settings/app_store_region.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/album_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/upload/pending_deletes.dart';
import 'package:photos_vault/upload/s3_object_delete.dart';
import 'package:photos_vault/upload/signing.dart';
import 'package:photos_vault/upload/sync_job_store.dart';

import 'tour_kit.dart';

/// One app, its own databases, its own bucket.
class Rig {
  Rig(this.t);

  final WidgetTester t;
  late final NativeFakes fakes;
  late final Problems problems;
  late final Crawler nav;
  late final AssetRecordStore store;
  late final AlbumStore albums;
  late final S3BackupTarget target;
  late final Directory dir;
  final targets = BackupTargetsStore();

  Future<void> setUp() async {
    await waitForPhotos();
    target = await freshTarget('flow');
    dir = await (await getTemporaryDirectory()).createTemp('flow');
    store = AssetRecordStore(path: p.join(dir.path, 'records.db'));
    albums = AlbumStore(path: p.join(dir.path, 'albums.db'));
    await AppStoreRegion.load();
    AppStoreRegion.languageChosen = true;
    AppStoreRegion.language.value = 'en';
    await DemoMode.init();
    fakes = NativeFakes(t)..install();
    problems = Problems(t)..install();
    nav = Crawler(t, problems);
  }

  Future<void> launch() async {
    await t.pumpWidget(
      App(
        assetRecordStore: store,
        albumStore: albums,
        syncJobStore: SyncJobStore(path: p.join(dir.path, 'jobs.db')),
        personStore: PersonStore(path: p.join(dir.path, 'people.db')),
      ),
    );
    await wait(2);
  }

  Future<void> tearDown() async {
    problems.uninstall();
    fakes.uninstall();
    // Unmounts the app so nothing outlives the test.
    await t.pumpWidget(const SizedBox());
    for (final line in problems.list) {
      say('FAIL $line');
    }
    expect(problems.list, isEmpty);
  }

  Future<void> wait(double seconds) async {
    for (var i = 0; i < seconds * 5; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    problems.check();
  }

  Future<void> until(
    Future<bool> Function() done, {
    String reason = '',
    int seconds = 30,
  }) async {
    for (var i = 0; i < seconds * 5; i++) {
      if (await done()) return;
      await t.pump(const Duration(milliseconds: 200));
    }
    problems.check();
    fail('timed out: $reason');
  }

  Future<void> untilShown(Finder finder, {int seconds = 20}) => until(
    () async => finder.hitTestable().evaluate().isNotEmpty,
    reason: '$finder',
    seconds: seconds,
  );

  Future<void> tap(Finder finder) async {
    await untilShown(finder);
    say('tap $finder');
    problems.where = '$finder';
    final before = problems.list.length;
    await t.tap(finder.hitTestable().first);
    await nav.settle();
    problems.check();
    if (problems.list.length > before) await nav.shot('problem');
  }

  Future<void> hold(Finder finder) async {
    await untilShown(finder);
    say('hold $finder');
    // A touch on a page still settling only stops it (ScrollStopGuard).
    await nav.settle();
    problems.where = 'hold $finder';
    await nav.holdAt(t.getCenter(finder.hitTestable().first));
    await nav.settle();
    problems.check();
  }

  Future<void> scrollTo(Finder finder) async {
    if (!await nav.tapWhenFound(finder)) fail('not found: $finder');
  }

  Future<AssetRecord> record(String id) async =>
      (await store.getByLocalId(id))!;

  Future<int> objectStatus(String key) async =>
      (await http.get(await presignGetUrl(target: target, key: key)))
          .statusCode;

  /// An imported photo, newest in the library so it opens on screen.
  Future<String> photo(
    String name, {
    bool backedUp = false,
    int minutesAgo = 0,
  }) async {
    final bytes = jpeg(300, 200, 30, 160, 90);
    final file = File(p.join(dir.path, '$name.jpg'))..writeAsBytesSync(bytes);
    final id = 'manual:$name';
    await store.upsert(
      localId: id,
      contentHash: name,
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: file.path,
      createdAt: DateTime.now().subtract(Duration(minutes: minutesAgo)),
      width: 300,
      height: 200,
    );
    if (backedUp) await upload(id, bytes, '${prefix}originals/$name.jpg');
    return id;
  }

  /// A photo saved into Photos with a record pointing at it.
  Future<String> libraryPhoto(String name, {bool backedUp = true}) async {
    final bytes = jpeg(64, 48, 200, 30, 90);
    final entity = await PhotoManager.editor.saveImage(
      bytes,
      filename: '$name.jpg',
    );
    final id = PhotoLibraryService.localIdFor(entity);
    await store.upsert(
      localId: id,
      contentHash: id,
      platform: 'ios',
      libraryId: entity.id,
      width: 64,
      height: 48,
      createdAt: DateTime.now(),
    );
    if (backedUp) await upload(id, bytes, '${prefix}originals/$name.jpg');
    return id;
  }

  Future<void> upload(String id, Uint8List bytes, String key) async {
    await put(target, key, bytes);
    await store.recordUpload(
      localId: id,
      kind: DerivativeKind.original,
      targetId: target.id,
      destinationKey: key,
    );
    await store.updateDerivative(
      id,
      DerivativeKind.original,
      DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
    );
  }

  /// Only in the bucket now.
  Future<(String, Uint8List)> cloudOnly(String name) async {
    final bytes = jpeg(320, 240, 220, 120, 20);
    final id = 'photo:$name/L0/001';
    await store.upsert(
      localId: id,
      contentHash: name,
      platform: 'ios',
      libraryId: '$name/L0/001',
      createdAt: DateTime.now(),
      width: 320,
      height: 240,
    );
    await upload(id, bytes, '${prefix}originals/$name.jpg');
    await store.setLocalDeleted(id, true);
    return (id, bytes);
  }

  Finder tile(String id) => find.byKey(ValueKey(id));

  Future<void> openPhoto(String id) async {
    await scrollTo(tile(id));
    await untilShown(find.text('Done'));
  }

  Future<void> home() => nav.home();

  Future<void> passcode(String code) async {
    for (final digit in code.split('')) {
      await t.tap(find.text(digit).hitTestable().last);
      await t.pump(const Duration(milliseconds: 120));
    }
    await nav.settle();
  }
}

void flow(String name, Future<void> Function(Rig r) body) =>
    testWidgets(name, (t) async {
      final rig = Rig(t);
      await rig.setUp();
      try {
        await body(rig);
      } catch (_) {
        await rig.nav.shot('FAIL ${name.split(':').first}');
        rethrow;
      } finally {
        await rig.tearDown();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  flow('favourite: on, listed in Favorites, off', (r) async {
    final id = await r.photo('fav');
    await r.launch();
    await r.openPhoto(id);
    await r.tap(find.byIcon(CupertinoIcons.heart));
    await r.until(() async => (await r.record(id)).isFavorite, reason: 'fav');
    expect(find.byIcon(CupertinoIcons.heart_fill), findsWidgets);
    await r.tap(find.text('Done'));
    await r.scrollTo(find.text('Favorites'));
    await r.untilShown(r.tile(id));
    await r.home();
    await r.openPhoto(id);
    await r.tap(find.byIcon(CupertinoIcons.heart_fill));
    await r.until(
      () async => !(await r.record(id)).isFavorite,
      reason: 'unfav',
    );
  });

  flow('delete: to Recently Deleted, recovered, then deleted for good and '
      'its bucket copy retracted', (r) async {
    final id = await r.photo('bin', backedUp: true);
    const key = '${prefix}originals/bin.jpg';
    await r.launch();

    await r.openPhoto(id);
    await r.scrollTo(find.text('Delete'));
    // Cancel first: nothing moves.
    await r.tap(find.text('Cancel'));
    expect((await r.record(id)).isDeleted, isFalse);
    await r.scrollTo(find.text('Delete'));
    await r.tap(find.text('Delete Photo'));
    await r.until(() async => isInBin(await r.record(id)), reason: 'binned');
    expect(await r.objectStatus(key), 200, reason: 'a bin keeps the backup');
    await r.home();
    expect(r.tile(id).evaluate(), isEmpty, reason: 'gone from the grid');

    await r.scrollTo(find.text('Recently Deleted'));
    await r.hold(r.tile(id));
    await r.tap(find.text('Recover'));
    await r.until(() async => !(await r.record(id)).isDeleted, reason: 'back');
    expect(r.tile(id).hitTestable().evaluate(), isEmpty);
    await r.home();
    await r.scrollTo(r.tile(id));
    await r.untilShown(find.text('Done'));

    await r.scrollTo(find.text('Delete'));
    await r.tap(find.text('Delete Photo'));
    await r.until(() async => isInBin(await r.record(id)), reason: 'binned 2');
    await r.home();
    await r.scrollTo(find.text('Recently Deleted'));
    await r.hold(r.tile(id));
    await r.tap(find.text('Delete Permanently'));
    await r.tap(find.text('Delete'));
    await r.until(
      () async => await r.store.getByLocalId(id) == null,
      reason: 'removed',
    );
    // Everything it ever had there: the first upload's name too, if a
    // re-upload while it was back moved it to another.
    await PendingDeletes(store: r.store).drain([r.target]);
    expect(await r.objectStatus(key), 404);
    expect(find.text('No items'), findsNothing);
  });

  flow('delete from Photos declined: the photo stays where it was', (r) async {
    final id = await r.libraryPhoto('declined');
    await r.launch();
    r.fakes.acceptDelete = false;
    await r.openPhoto(id);
    await r.scrollTo(find.text('Delete'));
    await r.tap(find.text('Delete Photo'));
    await r.wait(2);
    final after = await r.record(id);
    expect(after.isDeleted, isFalse);
    expect(after.libraryId, isNotNull);
    expect(r.fakes.deletePrompts, isNotEmpty);
  });

  flow('Download Full Resolution brings a cloud-only photo back', (r) async {
    final (id, bytes) = await r.cloudOnly('CLOUDFLOW');
    await r.launch();
    await r.openPhoto(id);
    await r.scrollTo(find.text('Download Full Resolution'));
    await r.until(
      () async => !(await r.record(id)).localDeleted,
      reason: 'downloaded',
    );
    final after = await r.record(id);
    expect(await File(after.sourcePath!).readAsBytes(), bytes);
    await r.wait(1);
    expect(find.text('Download Full Resolution'), findsNothing);
  });

  flow('album: made, a photo added from the grid, removed inside it', (
    r,
  ) async {
    final id = await r.photo('album-photo');
    await r.launch();
    await r.scrollTo(find.text('Albums'));
    await r.tap(
      find.descendant(
        of: find.ancestor(of: find.text('Albums'), matching: find.byType(Row)),
        matching: find.byIcon(CupertinoIcons.add_circled),
      ),
    );
    await enterText(r, 'Trip');
    await r.tap(find.text('Add'));
    await r.wait(1);
    final album = (await r.albums.listAll()).singleWhere(
      (a) => a.name == 'Trip',
    );

    await r.home();
    await r.scrollTo(r.tile(id));
    await r.untilShown(find.text('Done'));
    await r.tap(find.text('Done'));
    await r.hold(r.tile(id));
    await r.tap(find.text('Album'));
    await r.tap(find.text('Trip'));
    await r.until(
      () async => (await r.albums.localIdsIn(album.id)).contains(id),
      reason: 'added',
    );
    await r.home();
    await r.scrollTo(find.text('Trip'));
    await r.hold(r.tile(id));
    await r.tap(find.text('Remove from Album'));
    await r.until(
      () async => (await r.albums.localIdsIn(album.id)).isEmpty,
      reason: 'removed',
    );
    expect((await r.record(id)).isDeleted, isFalse);

    // Deleting the album leaves its photos alone.
    await r.albums.addAssets(album.id, [id]);
    await r.home();
    await r.nav.tapWhenFound(find.text('Trip'));
    await r.home();
    await r.hold(find.text('Trip'));
    await r.tap(find.text('Delete Album'));
    await r.tap(find.text('Delete Album'));
    await r.until(
      () async => (await r.albums.listAll()).every((a) => a.id != album.id),
      reason: 'album deleted',
    );
    expect((await r.record(id)).isDeleted, isFalse);
  });

  flow('a pending photo goes up to the bucket with its thumbnail', (r) async {
    final id = await r.photo('upload-me');
    await r.launch();
    await r.until(
      () async =>
          (await r.record(id)).stateOf(DerivativeKind.original).status ==
          UploadStatus.uploaded,
      reason: 'uploaded',
      seconds: 120,
    );
    final after = await r.record(id);
    final key = after.stateOf(DerivativeKind.original).destinationKey!;
    expect(await r.objectStatus(key), 200);
    await r.until(
      () async =>
          (await r.record(id)).stateOf(DerivativeKind.thumbnail).status ==
          UploadStatus.uploaded,
      reason: 'thumbnail',
      seconds: 60,
    );
    final thumb = (await r.record(id))
        .stateOf(DerivativeKind.thumbnail)
        .destinationKey!;
    expect(await r.objectStatus(thumb), 200);
  });

  flow('Check Now: a missing original is queued again, including one only '
      'a removed bucket held', (r) async {
    final missing = await r.photo('missing', minutesAgo: 5);
    await r.store.updateDerivative(
      missing,
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: '${prefix}originals/missing.jpg',
      ),
    );
    final elsewhere = await r.photo('elsewhere', minutesAgo: 6);
    await r.store.recordUpload(
      localId: elsewhere,
      kind: DerivativeKind.original,
      targetId: 'removed-target',
      destinationKey: 'old/originals/elsewhere.jpg',
    );
    await r.store.updateDerivative(
      elsewhere,
      DerivativeKind.original,
      const DerivativeState(
        status: UploadStatus.uploaded,
        destinationKey: 'old/originals/elsewhere.jpg',
      ),
    );
    final fine = await r.photo('fine', backedUp: true, minutesAgo: 7);
    // Keep the queue from fixing it before the check does.
    await r.targets.setQueuePaused(true);
    await r.launch();
    await r.scrollTo(find.text('Where Your Photos Are'));
    await r.tap(find.text('Check Now'));
    await r.until(
      () async =>
          (await r.record(missing)).stateOf(DerivativeKind.original).status ==
          UploadStatus.pending,
      reason: 'missing requeued',
    );
    await r.until(
      () async =>
          (await r.record(elsewhere)).stateOf(DerivativeKind.original).status ==
          UploadStatus.pending,
      reason: 'removed-bucket copy requeued',
    );
    expect(
      (await r.record(fine)).stateOf(DerivativeKind.original).status,
      UploadStatus.uploaded,
    );
    await r.targets.setQueuePaused(false);
  });

  flow('Flagged Items: a stray bucket photo is added to the library', (
    r,
  ) async {
    await r.photo('anchor', backedUp: true);
    final stray = jpeg(120, 90, 250, 250, 0);
    final key = '${prefix}originals/20200101120000_${'a' * 32}.jpg';
    await put(r.target, key, stray);
    await r.launch();
    await r.scrollTo(find.text('Flagged Items'));
    await r.tap(find.text('Add to Library'));
    await r.tap(find.byKey(const ValueKey('flagged-run')));
    await r.until(
      () async => (await r.store.listAll()).any(
        (rec) => rec.stateOf(DerivativeKind.original).destinationKey == key,
      ),
      reason: 'imported',
      seconds: 60,
    );
  });

  flow('hide from the grid, open with the right code and not the wrong one, '
      'then back to the library', (r) async {
    final id = await r.libraryPhoto('hide-ui');
    final libraryId = (await r.record(id)).libraryId;
    await r.launch();
    await r.scrollTo(r.tile(id));
    await r.tap(find.text('Done'));
    await r.hold(r.tile(id));
    await r.tap(find.text('More'));
    await r.tap(find.text('Hide'));
    for (final answer in ['Continue', 'Keep Originals']) {
      if (find.text(answer).evaluate().isNotEmpty) {
        await r.tap(find.text(answer));
      }
    }
    await r.passcode('2580');
    await r.passcode('2580');
    for (var i = 0; i < 20; i++) {
      for (final answer in ['Keep Originals', 'Download and Hide']) {
        if (find.text(answer).hitTestable().evaluate().isNotEmpty) {
          await r.tap(find.text(answer));
        }
      }
      if ((await r.record(id)).libraryId == null) break;
      await r.wait(0.5);
    }
    final hidden = await r.record(id);
    expect(hidden.passcodeHash, hashPasscode('2580'));
    expect(hidden.libraryId, isNull, reason: 'out of Photos');
    expect(r.fakes.deletePrompts.expand((ids) => ids), contains(libraryId));
    await r.home();
    expect(r.tile(id).evaluate(), isEmpty);

    // A wrong code opens an album of its own: empty, not this one.
    expect(await openHidden(r.nav, '1111'), isTrue);
    await r.wait(2);
    expect(r.tile(id).evaluate(), isEmpty);
    await r.home();

    expect(await openHidden(r.nav, '2580'), isTrue);
    await r.untilShown(r.tile(id));
    await r.hold(r.tile(id));
    await r.tap(find.textContaining('Library'));
    await r.until(
      () async => (await r.record(id)).passcodeHash == null,
      reason: 'unhidden',
    );
    await r.until(
      () async => (await r.record(id)).libraryId != null,
      reason: 'back in Photos',
    );
  });

  flow('settings: backup format and language', (r) async {
    await r.photo('settings');
    await r.launch();
    await r.scrollTo(find.text('Cloud Settings'));
    await r.scrollTo(find.text('Upload Quality'));
    await r.tap(find.text('Original'));
    await r.until(
      () async => await r.targets.getBackupFormat() == BackupFormat.original,
      reason: 'format',
    );
    await r.home();
    await r.scrollTo(find.text('Language'));
    await r.tap(find.text('中文'));
    await r.wait(1);
    expect(AppStoreRegion.language.value, 'zh');
    await r.home();
    expect(find.text('Recently Deleted'), findsNothing);
    AppStoreRegion.language.value = 'en';
    await r.wait(1);
  });

  flow('description and tags: typed, saved, removed', (r) async {
    final id = await r.photo('words');
    await r.launch();
    await r.openPhoto(id);
    final description = find.byWidgetPredicate(
      (w) => w is CupertinoTextField && w.placeholder == 'Add a description',
    );
    await r.scrollTo(description);
    await r.t.enterText(description.hitTestable().first, 'Sunset');
    await r.wait(1);
    await r.until(
      () async => (await r.record(id)).description == 'Sunset',
      reason: 'description',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await r.wait(0.5);
    await r.scrollTo(
      find.descendant(
        of: find.ancestor(of: find.text('Tags'), matching: find.byType(Row)),
        matching: find.byIcon(CupertinoIcons.add_circled),
      ),
    );
    await enterText(r, 'beach');
    await r.tap(find.text('Use "beach"'));
    await r.until(
      () async => (await r.record(id)).tags.contains('beach'),
      reason: 'tag',
    );
    await r.scrollTo(find.text('beach'));
    await r.tap(
      find.descendant(
        of: find.ancestor(of: find.text('beach'), matching: find.byType(Row)),
        matching: find.byIcon(CupertinoIcons.xmark_circle_fill),
      ),
    );
    await r.until(
      () async => (await r.record(id)).tags.isEmpty,
      reason: 'tag removed',
    );
  });

  flow('a cloud-only photo the bucket lost: Check Now says lost, marks it '
      'failed, and Flagged Items counts it', (r) async {
    final (id, _) = await r.cloudOnly('LOSTONE');
    final key = (await r.record(id))
        .stateOf(DerivativeKind.original)
        .destinationKey!;
    await deleteObject(target: r.target, key: key);
    await r.photo('kept', backedUp: true, minutesAgo: 3);
    await r.launch();
    await r.scrollTo(find.text('Where Your Photos Are'));
    await r.tap(find.text('Check Now'));
    await r.until(
      () async =>
          (await r.record(id)).stateOf(DerivativeKind.original).status ==
          UploadStatus.failed,
      reason: 'marked failed',
    );
    await r.untilShown(find.textContaining('has no copy on this phone'));
    await r.home();
    await r.scrollTo(find.text('Flagged Items'));
    await r.untilShown(find.text('1 photo is missing from the bucket'));
  });

  flow('Flagged Items: an odd file is hidden from the list and left in '
      'the bucket; exact copies lose all but one', (r) async {
    await r.photo('anchor2', backedUp: true);
    const odd = '${prefix}originals/holiday snap.jpg';
    await put(r.target, odd, jpeg(90, 60, 0, 0, 255));
    final same = jpeg(100, 100, 255, 255, 0);
    final a = '${prefix}originals/20200101120000_${'a' * 32}.jpg';
    final b = '${prefix}originals/20200101120001_${'b' * 32}.jpg';
    await put(r.target, a, same);
    await put(r.target, b, same);
    await r.launch();
    await r.scrollTo(find.text('Flagged Items'));
    await r.wait(3);
    await r.nav.shot('flagged list');

    await r.tap(find.text('Fix Names'));
    await r.tap(find.byKey(const ValueKey('flagged-hide')));
    await r.wait(1);
    await r.home();
    await r.scrollTo(find.text('Flagged Items'));
    await r.wait(3);
    expect(find.text('Fix Names'), findsNothing, reason: 'hidden from list');
    expect(await r.objectStatus(odd), 200);

    await r.tap(find.text('Delete Duplicates'));
    await r.tap(find.byKey(const ValueKey('flagged-run')));
    await r.tap(find.text('Delete Duplicates').last);
    await r.until(
      () async =>
          [
            await r.objectStatus(a),
            await r.objectStatus(b),
          ].where((s) => s == 200).length ==
          1,
      reason: 'one copy left',
      seconds: 60,
    );
  });
}

Future<void> enterText(Rig r, String text) async {
  final field = find.byType(CupertinoTextField).hitTestable();
  await r.untilShown(field);
  await r.t.enterText(field.first, text);
  await r.t.pump(const Duration(milliseconds: 200));
}

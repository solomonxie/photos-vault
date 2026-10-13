// The whole app against a fake S3, every control tapped. See README.md.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photos_vault/app.dart';
import 'package:photos_vault/demo/demo_mode.dart';
import 'package:photos_vault/settings/app_store_region.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';
import 'package:photos_vault/storage/album_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/passcode_hash.dart';

import 'tour_kit.dart';

const passcode = '2580';

/// Records of every kind the screens branch on, beside whatever the camera
/// roll scan finds.
Future<void> seed(S3BackupTarget target) async {
  final store = AssetRecordStore();
  final dir = Directory(
    p.join((await getApplicationSupportDirectory()).path, 'tour'),
  );
  await dir.create(recursive: true);

  Future<String> file(String name, Uint8List bytes) async {
    final f = File(p.join(dir.path, name));
    await f.writeAsBytes(bytes);
    return f.path;
  }

  Future<void> backedUp(String localId, Uint8List bytes, String key) async {
    await put(target, key, bytes);
    await store.recordUpload(
      localId: localId,
      kind: DerivativeKind.original,
      targetId: target.id,
      destinationKey: key,
    );
    await store.updateDerivative(
      localId,
      DerivativeKind.original,
      DerivativeState(status: UploadStatus.uploaded, destinationKey: key),
    );
  }

  // Imported files, one backed up, one with a lost original.
  for (var i = 0; i < 3; i++) {
    final bytes = jpeg(300, 200, 40 * i, 120, 200);
    final id = 'manual:tour-$i';
    await store.upsert(
      localId: id,
      contentHash: 'tour-$i',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: await file('tour-$i.jpg', bytes),
      createdAt: DateTime(2024, 5, 1 + i, 10),
      width: 300,
      height: 200,
    );
    if (i == 0) {
      await store.setDescription(id, 'A described photo');
      await store.setTags(id, ['tour', 'blue']);
      await store.setLocation(id, 'Lisbon');
      await store.setFavorite(id, true);
    }
    if (i == 1) {
      await backedUp(id, bytes, '${prefix}originals/20240502100000_tour1.jpg');
    }
    if (i == 2) {
      // Marked uploaded; the bucket never got it.
      await store.updateDerivative(
        id,
        DerivativeKind.original,
        const DerivativeState(
          status: UploadStatus.uploaded,
          destinationKey: '${prefix}originals/20240503100000_missing.jpg',
        ),
      );
    }
  }

  // Cloud-only.
  for (var i = 0; i < 2; i++) {
    final bytes = jpeg(320, 240, 200, 60 * i, 40);
    final id = 'photo:CLOUD-$i/L0/001';
    await store.upsert(
      localId: id,
      contentHash: 'cloud-$i',
      platform: 'ios',
      libraryId: 'CLOUD-$i/L0/001',
      createdAt: DateTime(2023, 3, 10 + i, 9),
      width: 320,
      height: 240,
    );
    await backedUp(
      id,
      bytes,
      '${prefix}originals/2023031${i}090000_cloud$i.jpg',
    );
    await store.setLocalDeleted(id, true);
  }

  // Recently deleted.
  final binned = 'manual:tour-binned';
  await store.upsert(
    localId: binned,
    contentHash: 'binned',
    platform: 'ios',
    sourceType: AssetSourceType.manualFile,
    sourcePath: await file('binned.jpg', jpeg(200, 200, 90, 90, 90)),
    createdAt: DateTime(2022, 1, 1),
  );
  await store.softDelete(binned);

  // Hidden behind [passcode].
  for (var i = 0; i < 2; i++) {
    final id = 'manual:tour-hidden-$i';
    await store.upsert(
      localId: id,
      contentHash: 'hidden-$i',
      platform: 'ios',
      sourceType: AssetSourceType.manualFile,
      sourcePath: await file('hidden-$i.jpg', jpeg(240, 320, 10, 200, 10)),
      createdAt: DateTime(2021, 6, 1 + i),
    );
    await store.setPasscodeHash(id, hashPasscode(passcode));
  }

  final albums = AlbumStore();
  await albums.upsert(id: 'tour-album', name: 'Tour Album');
  await albums.addAssets('tour-album', ['manual:tour-0', 'manual:tour-1']);
  await albums.upsert(id: 'tour-empty', name: 'Empty Album');

  // Bucket objects no record points at.
  final stray = jpeg(100, 100, 255, 255, 0);
  await put(target, '${prefix}originals/20200101120000_${'a' * 32}.jpg', stray);
  await put(target, '${prefix}originals/20200101120001_${'b' * 32}.jpg', stray);
  await put(
    target,
    '${prefix}originals/holiday snap.jpg',
    jpeg(90, 60, 0, 0, 255),
  );
  await put(
    target,
    '${prefix}thumbnails/20190101000000_${'c' * 32}.jpg',
    stray,
  );
}

/// Taps that would leave nothing for the rest of the crawl.
final denyAll = <Pattern>[
  'Remove All App Data',
  'Remove All Data',
  'Demo',
  'Erase',
  'Forget',
  'Delete All',
  'Empty',
  'Remove Bucket',
  'Remove Target',
  'Remove Backup',
  // Each has its own flow; here they would take the album the crawl is in.
  'Delete Album',
  'Delete Private Album',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tour: every screen, every control', (t) async {
    await waitForPhotos();
    final target = await freshTarget('tour');
    await seed(target);
    await AppStoreRegion.load();
    await DemoMode.init();

    final fakes = NativeFakes(t)..install();
    final problems = Problems(t)..install();
    try {
      await t.pumpWidget(const App());
      // Startup: camera roll scan, bucket listing, first uploads.
      for (var i = 0; i < 40; i++) {
        await t.pump(const Duration(milliseconds: 250));
      }
      problems.check();
      final crawler = Crawler(t, problems, deny: denyAll);
      await crawler.crawl(maxTaps: 300);

      // Places a blind crawl can't get into: behind a code, or one card in
      // a sideways row.
      await crawler.home();
      crawler.newPhase();
      if (await openHidden(crawler, passcode)) {
        await crawler.crawl(maxTaps: 120);
      }
      for (final album in ['Tour Album', 'Empty Album']) {
        await crawler.home();
        crawler.newPhase();
        if (await crawler.tapWhenFound(find.text(album))) {
          await crawler.crawl(maxTaps: 80);
        }
      }
      await crawler.home();
      crawler.newPhase();
      say('taps ${crawler.taps}, screens ${crawler.everVisited.length}');
      for (final s in crawler.spinners) {
        say('spinner $s');
      }
      for (final s in crawler.everVisited) {
        say('visited $s');
      }
    } finally {
      problems.uninstall();
      fakes.uninstall();
    }
    for (final line in problems.list) {
      say('FAIL $line');
    }
    expect(problems.list, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 90)));

  testWidgets('tour: the demo library — people, places, a hidden album', (
    t,
  ) async {
    await waitForPhotos();
    await AppStoreRegion.load();
    await DemoMode.init();
    await DemoMode.setActive(true);
    final fakes = NativeFakes(t)..install();
    final problems = Problems(t)..install();
    try {
      await t.pumpWidget(const App());
      for (var i = 0; i < 40; i++) {
        await t.pump(const Duration(milliseconds: 250));
      }
      problems.check();
      final crawler = Crawler(
        t,
        problems,
        deny: [...denyAll, 'Exit Demo', 'Reset Demo'],
      );
      await crawler.crawl(maxTaps: 150);
      for (final person in ['Maya Chen', 'Leo Park']) {
        await crawler.home();
        crawler.newPhase();
        if (await crawler.tapWhenFound(find.text(person))) {
          await crawler.crawl(maxTaps: 50);
        }
      }
      await crawler.home();
      crawler.newPhase();
      if (await openHidden(crawler, '1234')) {
        await crawler.crawl(maxTaps: 120);
      }
      await crawler.home();
      crawler.newPhase();
      say('demo taps ${crawler.taps}, screens ${crawler.everVisited.length}');
      for (final s in crawler.spinners) {
        say('spinner $s');
      }
      for (final s in crawler.everVisited) {
        say('visited $s');
      }
    } finally {
      problems.uninstall();
      fakes.uninstall();
      await t.pumpWidget(const SizedBox());
      await DemoMode.setActive(false);
    }
    for (final line in problems.list) {
      say('FAIL $line');
    }
    expect(problems.list, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 90)));
}

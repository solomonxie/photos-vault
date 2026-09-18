import 'package:photos_vault/backup/app_snapshot.dart';
import 'package:photos_vault/backup/backup_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_album_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

void main() {
  late FakeAssetRecordStore assets;
  late AppSnapshotIo io;
  late DateTime today;

  BackupSchedule newSchedule() => BackupSchedule(
    settings: assets,
    snapshots: io,
    markKey: 'somewhere_mark',
    atKey: 'somewhere_at',
    now: () => today,
  );

  setUp(() {
    assets = FakeAssetRecordStore();
    io = AppSnapshotIo(
      assetRecordStore: assets,
      albumStore: FakeAlbumStore(),
      personStore: FakePersonStore(),
    );
    today = DateTime(2026, 9, 18, 21);
  });

  test('a destination that has never run is due', () async {
    expect(await newSchedule().isDue(), isTrue);
  });

  test('twice in one day, never', () async {
    final schedule = newSchedule();
    await schedule.recordSuccess();

    assets.mark = 7;
    today = DateTime(2026, 9, 18, 23, 59);

    expect(await schedule.isDue(), isFalse);
  });

  test('a new day with nothing changed is skipped', () async {
    final schedule = newSchedule();
    await schedule.recordSuccess();

    today = DateTime(2026, 9, 19, 9);

    expect(await schedule.isDue(), isFalse);
  });

  test('a new day with a change is not', () async {
    final schedule = newSchedule();
    await schedule.recordSuccess();

    today = DateTime(2026, 9, 19, 9);
    assets.mark = 7;

    expect(await schedule.isDue(), isTrue);
  });

  test('a run that never happened is never remembered as done', () async {
    // The failure this guards: record the mark before the upload, and one
    // failed upload is remembered as done — the next day's gate sees no
    // change, skips, and goes on skipping forever.
    final schedule = newSchedule();
    assets.mark = 7;

    today = DateTime(2026, 9, 19, 9);
    expect(await schedule.isDue(), isTrue);
    expect(await schedule.lastRunAt(), isNull);

    today = DateTime(2026, 9, 20, 9);
    expect(await schedule.isDue(), isTrue);
  });

  test('two destinations fail independently', () async {
    final icloud = newSchedule();
    final bucket = BackupSchedule(
      settings: assets,
      snapshots: io,
      markKey: 'elsewhere_mark',
      atKey: 'elsewhere_at',
      now: () => today,
    );

    await icloud.recordSuccess();

    expect(await icloud.isDue(), isFalse);
    expect(await bucket.isDue(), isTrue);
  });
}

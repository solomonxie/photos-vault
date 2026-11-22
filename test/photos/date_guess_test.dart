import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/date_guess.dart';
import 'package:photos_vault/storage/asset_record.dart';

void main() {
  final now = DateTime(2026, 11, 20);

  test('dates cameras and apps write into file names', () {
    DateTime? d(String n) => dateInFileName(n, now: now);
    expect(d('IMG_20120304_101112.jpg'), DateTime(2012, 3, 4, 10, 11, 12));
    expect(d('IMG-20160612-WA0003.jpg'), DateTime(2016, 6, 12, 12));
    expect(
      d('Screenshot_2015-03-04-10-10-10.png'),
      DateTime(2015, 3, 4, 10, 10, 10),
    );
    expect(d('PXL_20210304_101010123.jpg'), DateTime(2021, 3, 4, 10, 10, 10));
    expect(d('2012-03-04 10.11.12.jpg'), DateTime(2012, 3, 4, 10, 11, 12));
  });

  test('no date: names without one, impossible days, the future, our own', () {
    DateTime? d(String n) => dateInFileName(n, now: now);
    expect(d('DSC_0042.JPG'), isNull);
    expect(d('IMG_20120231_101010.jpg'), isNull, reason: '31 Feb');
    expect(d('IMG_20300101.jpg'), isNull, reason: 'still to come');
    expect(
      d('20051029122604_2f17985fc6585548eedb2e53a1f18395.heic'),
      isNull,
      reason: "the backup's own name carries the stored date",
    );
  });

  AssetRecord record(
    String id, {
    required DateTime created,
    DateTime? added,
    String? path,
    AssetSourceType type = AssetSourceType.manualFile,
    DateTime? dateSetAt,
  }) => AssetRecord(
    localId: id,
    contentHash: id,
    platform: 'ios',
    sourceType: type,
    sourcePath: path,
    createdAt: created,
    updatedAt: created,
    addedAt: added,
    dateSetAt: dateSetAt,
  );

  test('a file name that says another day, and a file dated when added', () {
    final added = DateTime(2026, 5, 1, 9);
    final checks = datesToCheck([
      record(
        'named',
        created: added,
        added: added,
        path: '/x/IMG_20120304_101112.jpg',
      ),
      record('bare', created: added, added: added, path: '/x/scan.jpg'),
      record(
        'fine',
        created: DateTime(2012, 3, 4, 10),
        added: added,
        path: '/x/IMG_20120304_101112.jpg',
      ),
      record(
        'set by hand',
        created: added,
        added: added,
        path: '/x/scan2.jpg',
        dateSetAt: added,
      ),
      record(
        'camera roll',
        created: added,
        added: added,
        type: AssetSourceType.photoManager,
      ),
    ], now: now);
    expect(
      {for (final c in checks) c.record.localId: c.reason},
      {
        'named': DateCheckReason.nameDisagrees,
        'bare': DateCheckReason.noOwnDate,
      },
    );
    expect(
      checks.firstWhere((c) => c.record.localId == 'named').proposed,
      DateTime(2012, 3, 4, 10, 11, 12),
    );
  });
}

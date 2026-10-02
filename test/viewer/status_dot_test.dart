import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/asset_grid.dart';

AssetRecord _record({
  bool localDeleted = false,
  UploadStatus status = UploadStatus.pending,
  bool isLivePhoto = false,
  UploadStatus live = UploadStatus.pending,
}) => AssetRecord(
  localId: 'manual:a',
  contentHash: 'a',
  platform: 'test',
  sourceType: AssetSourceType.manualFile,
  sourcePath: '/tmp/a.jpg',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  localDeleted: localDeleted,
  isLivePhoto: isLivePhoto,
  derivatives: {
    DerivativeKind.original: DerivativeState(status: status),
    DerivativeKind.livePhoto: DerivativeState(status: live),
  },
);

Future<void> _pump(WidgetTester tester, AssetRecord record) =>
    tester.pumpWidget(CupertinoApp(home: StatusDot(record: record)));

void main() {
  testWidgets('a photo only in the bucket wears a cloud', (tester) async {
    await _pump(
      tester,
      _record(localDeleted: true, status: UploadStatus.uploaded),
    );

    expect(find.byIcon(CupertinoIcons.cloud_fill), findsOneWidget);
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(
      icon.shadows,
      isNotEmpty,
      reason: 'white on a white photo is nothing at all',
    );
  });

  testWidgets('so does one in both places', (tester) async {
    await _pump(tester, _record(status: UploadStatus.uploaded));

    expect(find.byIcon(CupertinoIcons.cloud_fill), findsOneWidget);
  });

  testWidgets('one not backed up yet wears no cloud', (tester) async {
    await _pump(tester, _record());

    expect(find.byIcon(CupertinoIcons.cloud_fill), findsNothing);
  });

  test('the underline says how much is safe', () {
    expect(
      BackupLine.of(_record(status: UploadStatus.uploaded)),
      BackupLine.safe,
    );
    expect(BackupLine.of(_record()), BackupLine.pending);
    expect(
      BackupLine.of(_record(status: UploadStatus.uploading)),
      BackupLine.uploading,
    );
    expect(
      BackupLine.of(_record(status: UploadStatus.failed)),
      BackupLine.failed,
    );
  });

  test('a Live Photo with its still up is partly green', () {
    final record = _record(
      isLivePhoto: true,
      status: UploadStatus.uploaded,
      live: UploadStatus.uploading,
    );

    expect(BackupLine.of(record), BackupLine.uploading);
    expect(BackupLine.safeShare(record), 0.75);
  });
}

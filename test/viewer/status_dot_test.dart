import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/asset_grid.dart';

AssetRecord _record({
  bool localDeleted = false,
  UploadStatus status = UploadStatus.pending,
  bool isLivePhoto = false,
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
  derivatives: {DerivativeKind.original: DerivativeState(status: status)},
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

  testWidgets('one not backed up yet wears the ring instead', (tester) async {
    await _pump(tester, _record());

    expect(find.byIcon(CupertinoIcons.cloud_fill), findsNothing);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('one in both places wears nothing', (tester) async {
    await _pump(tester, _record(status: UploadStatus.uploaded));

    expect(find.byIcon(CupertinoIcons.cloud_fill), findsNothing);
    expect(find.byType(SizedBox), findsOneWidget);
  });
}

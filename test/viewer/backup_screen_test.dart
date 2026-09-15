import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:bring_your_own_photos/viewer/backup_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_asset_record_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  testWidgets('shows the empty state with nothing tracked yet', (tester) async {
    await tester.pumpWidget(_wrap(BackupScreen(assetRecordStore: FakeAssetRecordStore())));
    await tester.pumpAndSettle();

    expect(find.text('Nothing Backed Up Yet'), findsOneWidget);
  });

  testWidgets('shows real counts per derivative status', (tester) async {
    final store = FakeAssetRecordStore();
    await store.upsert(localId: 'a', contentHash: 'a', platform: 'ios');
    final b = await store.upsert(localId: 'b', contentHash: 'b', platform: 'ios');
    await store.updateDerivative(
      b.localId,
      DerivativeKind.original,
      const DerivativeState(status: UploadStatus.uploaded, destinationKey: 'originals/b.jpg'),
    );

    await tester.pumpWidget(_wrap(BackupScreen(assetRecordStore: store)));
    await tester.pumpAndSettle();

    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('1'), findsNWidgets(2)); // 1 pending, 1 uploaded
    expect(find.text('Backed up'), findsOneWidget);
  });
}

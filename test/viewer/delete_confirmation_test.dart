import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/asset_removal.dart';
import 'package:photos_vault/viewer/delete_confirmation.dart';

import '../support/fake_asset_record_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

/// Opens the sheet on the first frame so the test only has to read it.
Widget _opener({required bool recoverable}) => Builder(
  builder: (context) => CupertinoButton(
    onPressed: () => chooseDelete(
      context,
      canRemoveFromDevice: false,
      recoverable: recoverable,
    ),
    child: const Text('delete'),
  ),
);

void main() {
  testWidgets('a photo with a copy elsewhere is promised the bin', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_opener(recoverable: true)));
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();

    expect(find.text('It will be moved to Recently Deleted.'), findsOneWidget);
  });

  testWidgets('a photo with nothing behind it is not', (tester) async {
    await tester.pumpWidget(_wrap(_opener(recoverable: false)));
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();

    expect(find.text('It will be moved to Recently Deleted.'), findsNothing);
    expect(
      find.text(
        "This item isn't backed up, so it will be deleted permanently.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('a locked photo says so instead of doing nothing', (
    tester,
  ) async {
    final store = FakeAssetRecordStore();
    final record = (await store.upsert(
      localId: 'photo:1',
      contentHash: '1',
      platform: 'ios',
    )).withLocked(true);
    DeleteOutcome? outcome;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async => outcome = await deleteAsset(
              context,
              record: record,
              removal: AssetRemoval(store: store),
            ),
            child: const Text('delete'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();

    expect(
      find.text('This photo is locked. Unlock it to delete it.'),
      findsOneWidget,
    );
    expect(find.text('It will be moved to Recently Deleted.'), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(outcome, DeleteOutcome.none);
  });
}

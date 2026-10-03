import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/viewer/delete_confirmation.dart';

Future<DeleteChoice?> _open(
  WidgetTester tester, {
  required int removable,
}) async {
  DeleteChoice? picked;
  await tester.pumpWidget(
    CupertinoApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => CupertinoButton(
          onPressed: () async => picked = await chooseBatchDelete(
            context,
            count: 3,
            removable: removable,
          ),
          child: const Text('go'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  return picked;
}

void main() {
  testWidgets('backed-up photos in a selection can leave just the device', (
    tester,
  ) async {
    await _open(tester, removable: 2);
    expect(find.text('Remove 2 from Device'), findsOneWidget);
    await tester.tap(find.text('Remove 2 from Device'));
    await tester.pumpAndSettle();
  });

  testWidgets('with nothing backed up, only delete is offered', (tester) async {
    await _open(tester, removable: 0);
    expect(find.byKey(const ValueKey('batchRemoveFromDevice')), findsNothing);
  });
}

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/viewer/delete_confirmation.dart';

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

    expect(find.text('It moves to Recently Deleted.'), findsOneWidget);
  });

  testWidgets('a photo with nothing behind it is not', (tester) async {
    await tester.pumpWidget(_wrap(_opener(recoverable: false)));
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();

    expect(find.text('It moves to Recently Deleted.'), findsNothing);
    expect(
      find.text("It isn't backed up, so this deletes it for good."),
      findsOneWidget,
    );
  });
}

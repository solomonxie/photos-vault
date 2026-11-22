import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/viewer/date_editor.dart';

Widget _host(Future<void> Function(BuildContext) open) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (context) => CupertinoButton(
      onPressed: () => open(context),
      child: const Text('open'),
    ),
  ),
);

void main() {
  test('shifting keeps the day where the month has it', () {
    expect(
      shiftDate(DateTime(2020, 3, 31, 9), months: -1),
      DateTime(2020, 2, 29, 9),
    );
    expect(
      shiftDate(DateTime(2020, 1, 15), years: -10, days: 2),
      DateTime(2010, 1, 17),
    );
  });

  testWidgets('a year typed, not spun, and a guess is one tap', (tester) async {
    DateTime Function(DateTime)? change;
    await tester.pumpWidget(
      _host(
        (context) async => change = await showDateEditor(
          context,
          initial: DateTime(2026, 5, 1, 9, 30),
          guesses: [
            (label: 'From the file name', date: DateTime(2012, 3, 4, 10, 11)),
          ],
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('dateEdit:year')), '2009');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dateEditSave')));
    await tester.pumpAndSettle();
    expect(change!(DateTime(2026)), DateTime(2009, 5, 1, 9, 30));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('dateGuess:From the file name')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dateEditSave')));
    await tester.pumpAndSettle();
    expect(change!(DateTime(2026)), DateTime(2012, 3, 4, 10, 11));
  });

  testWidgets('a day that does not exist cannot be saved', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showDateEditor(context, initial: DateTime(2020, 2, 1)),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('dateEdit:day')), '31');
    await tester.pump();
    expect(find.text('Not a real date'), findsOneWidget);
    final save = tester.widget<CupertinoButton>(
      find.byKey(const ValueKey('dateEditSave')),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('many photos shift together, keeping their order', (
    tester,
  ) async {
    DateTime Function(DateTime)? change;
    await tester.pumpWidget(
      _host(
        (context) async => change = await showDateEditor(
          context,
          initial: DateTime(2026, 5, 1),
          count: 3,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shift All By'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('dateEdit:years')), '12');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dateEditSave')));
    await tester.pumpAndSettle();
    expect(change!(DateTime(2026, 5, 1, 8)), DateTime(2014, 5, 1, 8));
    expect(change!(DateTime(2026, 5, 2, 9)), DateTime(2014, 5, 2, 9));
  });
}

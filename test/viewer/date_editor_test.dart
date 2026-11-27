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

  testWidgets('the date opens its own wheels, and a guess is one tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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

    expect(find.byKey(const ValueKey('datePicker')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('dateRow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('datePicker')), findsOneWidget);
    // The year wheel is the right-most column.
    final picker = tester.getRect(find.byKey(const ValueKey('datePicker')));
    await tester.dragFrom(
      Offset(picker.center.dx + 100, picker.center.dy),
      const Offset(0, 200),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dateEditSave')));
    await tester.pumpAndSettle();
    final moved = change!(DateTime(2026));
    expect(moved.year, isNot(2026));
    expect((moved.month, moved.day, moved.hour, moved.minute), (5, 1, 9, 30));

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

  testWidgets('either part can be left alone', (tester) async {
    DateTime Function(DateTime)? change;
    await tester.pumpWidget(
      _host(
        (context) async => change = await showDateEditor(
          context,
          initial: DateTime(2020, 2, 1, 8, 15),
          guesses: [(label: 'Guess', date: DateTime(2012, 3, 4, 10, 11))],
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dateGuess:Guess')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('timeRowSwitch')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dateEditSave')));
    await tester.pumpAndSettle();
    expect(change!(DateTime(2026, 7, 9, 21, 5)), DateTime(2012, 3, 4, 21, 5));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dateGuess:Guess')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dateRowSwitch')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('dateEditSave')));
    await tester.pumpAndSettle();
    expect(change!(DateTime(2026, 7, 9, 21, 5)), DateTime(2026, 7, 9, 10, 11));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dateRowSwitch')));
    await tester.tap(find.byKey(const ValueKey('timeRowSwitch')));
    await tester.pump();
    final save = tester.widget<CupertinoButton>(
      find.byKey(const ValueKey('dateEditSave')),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('time has its own row of wheels', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showDateEditor(context, initial: DateTime(2020, 2, 1, 8)),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('timeRow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timePicker')), findsOneWidget);
    expect(find.byKey(const ValueKey('datePicker')), findsNothing);
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

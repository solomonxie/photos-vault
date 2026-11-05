import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/viewer/select_all.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: CupertinoPageScaffold(child: Center(child: child)),
);

void main() {
  test('Select All takes everything, whatever was picked', () {
    final ids = [for (var i = 0; i < 250; i++) i];
    expect(selectEverything(ids, {249, 7}).length, 250);
  });

  testWidgets('a hundred or fewer select at once; more ask first', (
    tester,
  ) async {
    var selected = 0;
    Future<void> show(int total) => tester.pumpWidget(
      _wrap(
        SelectAllButton(
          total: total,
          selectedCount: 0,
          onSelectNext: () => selected++,
          onDeselectAll: () {},
        ),
      ),
    );

    await show(100);
    await tester.tap(find.byKey(const ValueKey('selectAllButton')));
    await tester.pumpAndSettle();
    expect(selected, 1);

    await show(3000);
    await tester.tap(find.byKey(const ValueKey('selectAllButton')));
    await tester.pumpAndSettle();
    expect(find.text('Select all 3000?'), findsOne);
    expect(selected, 1);
    await tester.tap(find.byKey(const ValueKey('selectAllConfirm')));
    await tester.pumpAndSettle();
    expect(selected, 2);
  });
}

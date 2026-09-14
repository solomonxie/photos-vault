import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/photos/person.dart';
import 'package:back_your_own_photos/viewer/person_history_detail_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_person_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

void main() {
  testWidgets('renaming via the title row persists the new title', (tester) async {
    final personStore = FakePersonStore();
    const entry = PersonHistoryEntry(id: 'e1', personId: 'p1', category: HistoryCategory.education, title: 'MIT');

    await tester.pumpWidget(
      _wrap(PersonHistoryDetailScreen(entry: entry, categoryLabel: 'Education', personStore: personStore)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('MIT'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(CupertinoSearchTextField), 'Stanford');
    await tester.pump();
    await tester.tap(find.text('Use "Stanford"'));
    await tester.pumpAndSettle();

    expect(find.text('Stanford'), findsOneWidget);
    final saved = await personStore.historyFor('p1', HistoryCategory.education);
    expect(saved.single.title, 'Stanford');
  });

  testWidgets('End defaults to Present, and can be set to a specific date', (tester) async {
    final personStore = FakePersonStore();
    const entry = PersonHistoryEntry(id: 'e1', personId: 'p1', category: HistoryCategory.job, title: 'Acme Corp');

    await tester.pumpWidget(
      _wrap(PersonHistoryDetailScreen(entry: entry, categoryLabel: 'Job', personStore: personStore)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Present'), findsOneWidget);

    await tester.tap(find.text('End'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('End Date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = await personStore.historyFor('p1', HistoryCategory.job);
    expect(saved.single.endDate, isNotNull);
  });

  testWidgets('adding a custom field persists label and value', (tester) async {
    final personStore = FakePersonStore();
    const entry = PersonHistoryEntry(id: 'e1', personId: 'p1', category: HistoryCategory.job, title: 'Acme Corp');

    await tester.pumpWidget(
      _wrap(PersonHistoryDetailScreen(entry: entry, categoryLabel: 'Job', personStore: personStore)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.add_circled));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(CupertinoTextField, 'Field'), 'Title');
    await tester.pump();
    await tester.enterText(find.widgetWithText(CupertinoTextField, 'Value'), 'Senior Engineer');
    await tester.pump();

    final saved = await personStore.historyFor('p1', HistoryCategory.job);
    expect(saved.single.customFields.single.label, 'Title');
    expect(saved.single.customFields.single.value, 'Senior Engineer');
  });

  testWidgets('Delete Entry removes it from the store', (tester) async {
    final personStore = FakePersonStore();
    const entry = PersonHistoryEntry(id: 'e1', personId: 'p1', category: HistoryCategory.job, title: 'Acme Corp');
    await personStore.addHistoryEntry(entry);

    await tester.pumpWidget(
      _wrap(PersonHistoryDetailScreen(entry: entry, categoryLabel: 'Job', personStore: personStore)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete Entry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(await personStore.historyFor('p1', HistoryCategory.job), isEmpty);
  });
}

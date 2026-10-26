import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/viewer/developer_options_screen.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';
import '../support/fake_person_store.dart';

void main() {
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DeveloperOptionsScreen(
          personStore: FakePersonStore(),
          assetRecordStore: FakeAssetRecordStore(),
          analysisStore: FakeAiAnalysisStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('every import is listed, its details folded', (tester) async {
    await open(tester);

    for (final key in [
      'devCsvImport',
      'devCsvExport',
      'devZipImport',
      'devFacesImport',
      'devChatsImport',
    ]) {
      await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 200);
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
    expect(find.textContaining('mode (per row)'), findsNothing);
  });

  testWidgets('File format opens to the spec and an example, and folds back', (
    tester,
  ) async {
    await open(tester);
    final format = find.descendant(
      of: find.byKey(const ValueKey('devCsvImport')),
      matching: find.text('File format'),
    );

    await tester.tap(format);
    await tester.pumpAndSettle();
    expect(find.textContaining('mode (per row)'), findsOneWidget);
    expect(find.textContaining('Ava Chen,1990-04'), findsOneWidget);

    await tester.tap(format);
    await tester.pumpAndSettle();
    expect(find.textContaining('mode (per row)'), findsNothing);
  });
}

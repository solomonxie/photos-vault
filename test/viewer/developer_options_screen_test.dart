import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/arrival_log.dart';
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

  testWidgets('new photos\' timing reads stage by stage', (tester) async {
    final log = ArrivalLog.shared;
    log.start('change')
      ..mark('looked up')
      ..mark('shown')
      ..finish(2);
    log.start('resume').finish(0);
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CupertinoPageScaffold(child: ArrivalTimings(log: log)),
      ),
    );
    expect(log.entries.value, hasLength(1), reason: 'nothing came: not kept');
    expect(find.textContaining('change · 2 photos'), findsOneWidget);
    expect(find.textContaining('looked up'), findsOneWidget);
    expect(find.textContaining('→  shown'), findsOneWidget);
  });
}

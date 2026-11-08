import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/viewer/date_time_sheet.dart';

void main() {
  testWidgets('the date has a year to pick, and Save keeps date and time', (
    tester,
  ) async {
    DateTime? picked;
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async => picked = await showDateTimeSheet(
              context,
              initial: DateTime(2009, 7, 14, 18, 25),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('2009'), findsWidgets);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(picked, DateTime(2009, 7, 14, 18, 25));
  });
}

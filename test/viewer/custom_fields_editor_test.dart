import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/viewer/custom_fields_editor.dart';

void main() {
  testWidgets('more than five fields fold; adding one opens them', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CupertinoPageScaffold(
          child: SingleChildScrollView(
            child: CustomFieldsEditor(
              initialFields: [
                for (var i = 0; i < 8; i++)
                  PersonCustomField(label: 'k$i', value: 'v$i'),
              ],
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('v4'), findsOneWidget);
    expect(find.text('v5'), findsNothing);
    await tester.tap(find.text('Show All (8)'));
    await tester.pump();
    expect(find.text('v7'), findsOneWidget);
    await tester.tap(find.text('Show Less'));
    await tester.pump();
    expect(find.text('v7'), findsNothing);
    await tester.tap(find.byKey(customFieldsAddKey));
    await tester.pump();
    expect(find.text('v7'), findsOneWidget);
  });
}

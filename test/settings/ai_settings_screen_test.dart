import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/settings/ai_settings_screen.dart';
import 'package:back_your_own_photos/settings/ai_settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_secure_store.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: child,
  );
}

void main() {
  testWidgets('saving an OpenAI API key persists it and shows the usage warning', (tester) async {
    final aiSettingsStore = AiSettingsStore(store: FakeSecureStore());
    await tester.pumpWidget(_wrap(AiSettingsScreen(aiSettingsStore: aiSettingsStore)));
    await tester.pumpAndSettle();

    expect(find.text('AI Settings'), findsOneWidget);
    expect(find.textContaining('incurs API usage charges'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'OpenAI API key'), 'sk-test');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('API key saved'), findsOneWidget);
    expect(await aiSettingsStore.readOpenAiApiKey(), 'sk-test');

    // Flush the first SnackBar's auto-dismiss timer so the second one
    // (queued behind it) shows immediately after the next tap.
    await tester.pump(const Duration(seconds: 5));

    await tester.tap(find.text('Remove Key'));
    await tester.pumpAndSettle();

    expect(find.text('API key removed'), findsOneWidget);
    expect(await aiSettingsStore.readOpenAiApiKey(), isNull);
  });
}

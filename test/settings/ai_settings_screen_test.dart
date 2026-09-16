import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/photos/ai_vendor.dart';
import 'package:bring_your_own_photos/settings/ai_settings_screen.dart';
import 'package:bring_your_own_photos/settings/ai_settings_store.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_secure_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

/// Adding is a half sheet: open it, pick a vendor if it isn't the default,
/// type the key, Save.
Future<void> _addKey(
  WidgetTester tester, {
  required String secret,
  String? vendor,
}) async {
  await tester.tap(find.text('Add AI Key'));
  await tester.pumpAndSettle();
  if (vendor != null) {
    await tester.tap(find.text('Vendor'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(vendor));
    await tester.pumpAndSettle();
  }
  await tester.enterText(find.byType(CupertinoTextField), secret);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a saved key becomes a row, and the sheet closes behind it', (
    tester,
  ) async {
    final store = AiSettingsStore(store: FakeSecureStore());
    await tester.pumpWidget(_wrap(AiSettingsScreen(aiSettingsStore: store)));
    await tester.pumpAndSettle();

    expect(find.text('AI Settings'), findsOneWidget);
    expect(find.textContaining('incurs API usage charges'), findsOneWidget);
    // No form parked under the list — just the link that opens one.
    expect(find.byType(CupertinoTextField), findsNothing);

    await _addKey(tester, secret: 'sk-test');

    // The filled row is the confirmation; no toast needed.
    expect(find.byType(CupertinoTextField), findsNothing);
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('0 requests'), findsOneWidget);

    final keys = await store.listKeys();
    expect(keys.single.vendor, AiVendor.openai);
    expect(keys.single.secret, 'sk-test');
  });

  testWidgets('every vendor is offered, not just OpenAI', (tester) async {
    final store = AiSettingsStore(store: FakeSecureStore());
    await tester.pumpWidget(_wrap(AiSettingsScreen(aiSettingsStore: store)));
    await tester.pumpAndSettle();

    await _addKey(tester, secret: 'sk-ant-test', vendor: 'Anthropic');

    expect(find.text('Anthropic'), findsOneWidget);
    expect((await store.listKeys()).single.vendor, AiVendor.anthropic);
  });

  testWidgets('removing a key is confirmed first', (tester) async {
    final store = AiSettingsStore(store: FakeSecureStore());
    await store.addKey(AiVendor.openai, 'sk-test');
    await tester.pumpWidget(_wrap(AiSettingsScreen(aiSettingsStore: store)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
    await tester.pumpAndSettle();
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Remove Key'));
    await tester.pumpAndSettle();

    expect(await store.listKeys(), isEmpty);
  });

  group('fallback strategy', () {
    testWidgets('is inert until there is a second key to fall back to', (
      tester,
    ) async {
      final store = AiSettingsStore(store: FakeSecureStore());
      await store.addKey(AiVendor.openai, 'sk-test');
      await tester.pumpWidget(_wrap(AiSettingsScreen(aiSettingsStore: store)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sequential'));
      await tester.pumpAndSettle();

      expect(find.text('Sequential'), findsOneWidget);
      expect(await store.getStrategy(), AiKeyStrategy.sequential);
    });

    testWidgets('toggles between Sequential and Round Robin', (tester) async {
      final store = AiSettingsStore(store: FakeSecureStore());
      await store.addKey(AiVendor.openai, 'sk-one');
      await store.addKey(AiVendor.anthropic, 'sk-two');
      await tester.pumpWidget(_wrap(AiSettingsScreen(aiSettingsStore: store)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sequential'));
      await tester.pumpAndSettle();

      expect(find.text('Round Robin'), findsOneWidget);
      expect(await store.getStrategy(), AiKeyStrategy.roundRobin);
    });
  });
}

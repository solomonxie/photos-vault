import 'package:back_your_own_photos/l10n/app_localizations.dart';
import 'package:back_your_own_photos/settings/aws_settings_store.dart';
import 'package:back_your_own_photos/settings/settings_screen.dart';
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
  Future<void> useTallSurface(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('shows a validation error when saving with empty required fields', (tester) async {
    await useTallSurface(tester);
    final store = AwsSettingsStore(store: FakeSecureStore());
    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Required'), findsWidgets);
  });

  testWidgets('saves and reloads entered credentials', (tester) async {
    await useTallSurface(tester);
    final store = AwsSettingsStore(store: FakeSecureStore());
    await tester.pumpWidget(_wrap(SettingsScreen(store: store)));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Access key ID'), 'AKIA123');
    await tester.enterText(find.widgetWithText(TextFormField, 'Secret access key'), 'topsecret');
    await tester.enterText(find.widgetWithText(TextFormField, 'Region'), 'us-east-1');
    await tester.enterText(find.widgetWithText(TextFormField, 'Bucket'), 'my-bucket');

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Settings saved'), findsOneWidget);

    final saved = await store.load();
    expect(saved.accessKeyId, 'AKIA123');
    expect(saved.bucket, 'my-bucket');
    expect(saved.hasCredentials, isTrue);
  });
}

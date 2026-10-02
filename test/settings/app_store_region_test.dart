import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/settings/app_store_region.dart';

void main() {
  const supported = AppLocalizations.supportedLocales;

  test('a China build defaults to Chinese', () {
    expect(
      storefrontLocale(
        supported,
        region: AppStoreRegion.cn,
        languageChosen: false,
      ),
      const Locale('zh'),
    );
  });

  test('a language picked for the app wins over the China default', () {
    expect(
      storefrontLocale(
        supported,
        region: AppStoreRegion.cn,
        languageChosen: true,
      ),
      isNull,
    );
  });

  test('a US build leaves the device language alone', () {
    expect(
      storefrontLocale(
        supported,
        region: AppStoreRegion.us,
        languageChosen: false,
      ),
      isNull,
    );
  });

  test('no Chinese localization, no default', () {
    expect(
      storefrontLocale(
        const [Locale('en')],
        region: AppStoreRegion.cn,
        languageChosen: false,
      ),
      isNull,
    );
  });

  testWidgets('the app follows it: China build on an English phone', (
    tester,
  ) async {
    tester.platformDispatcher.localesTestValue = const [Locale('en', 'US')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    Locale? shown;
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        supportedLocales: supported,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        localeListResolutionCallback: (_, s) => storefrontLocale(
          s,
          region: AppStoreRegion.cn,
          languageChosen: false,
        ),
        builder: (context, _) {
          shown = Localizations.localeOf(context);
          return const SizedBox();
        },
      ),
    );
    expect(shown, const Locale('zh'));
  });

  testWidgets('picking English in the app beats the China default', (
    tester,
  ) async {
    Locale? shown;
    await tester.pumpWidget(
      WidgetsApp(
        color: const Color(0xFF000000),
        locale: const Locale('en'),
        supportedLocales: supported,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        localeListResolutionCallback: (_, s) => storefrontLocale(
          s,
          region: AppStoreRegion.cn,
          languageChosen: false,
          picked: 'en',
        ),
        builder: (context, _) {
          shown = Localizations.localeOf(context);
          return const SizedBox();
        },
      ),
    );
    expect(shown, const Locale('en'));
  });
}

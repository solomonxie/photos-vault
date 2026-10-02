import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Storefront the build was made for: `make <build> STOREFRONT=USA|CAN|CHN`
/// (USA/CAN -> us, CHN -> cn), read from Info.plist `AppStoreRegion`. For
/// vendor gating (docs/release) and the default language.
enum AppStoreRegion {
  us,
  cn;

  static AppStoreRegion current = us;

  /// A language picked for this app in iOS Settings, which beats [cn]'s
  /// default.
  static bool languageChosen = false;

  /// Picked in the app's own Language row: `en`, `zh`, or null to follow
  /// the system. Beats both of the above.
  static final language = ValueNotifier<String?>(null);

  static const _channel = MethodChannel('byo.photos/app_store');

  /// Before `runApp`. Anything unreadable stays [us], nothing chosen.
  static Future<void> load() async {
    try {
      final name = await _channel.invokeMethod<String>('region');
      current = values.firstWhere((r) => r.name == name, orElse: () => us);
      languageChosen =
          await _channel.invokeMethod<bool>('languageChosen') ?? false;
      language.value = await _channel.invokeMethod<String>('language');
    } catch (_) {}
  }

  static Future<void> setLanguage(String? code) async {
    language.value = code;
    try {
      await _channel.invokeMethod<void>('setLanguage', code);
    } catch (_) {}
  }
}

/// For `localeListResolutionCallback`: a [AppStoreRegion.cn] build opens
/// in Chinese unless a language was chosen; `null` leaves Flutter's usual
/// device-language resolution.
Locale? storefrontLocale(
  Iterable<Locale> supported, {
  required AppStoreRegion region,
  required bool languageChosen,
  String? picked,
}) {
  // Flutter runs this on an explicit `locale` too; the pick must win.
  if (picked != null) return null;
  if (region != AppStoreRegion.cn || languageChosen) return null;
  for (final locale in supported) {
    if (locale.languageCode == 'zh') return locale;
  }
  return null;
}

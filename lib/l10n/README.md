# l10n

Localized strings — English and Mandarin, from the start.

```text
app_en.arb / app_zh.arb        (source strings, hand-edited)
        │ `flutter gen-l10n`                       (../../l10n.yaml)
        ▼
app_localizations.dart          (generated — base class + delegate, gitignored)
app_localizations_en.dart       (generated — gitignored)
app_localizations_zh.dart       (generated — gitignored)
        ▲
        │ AppLocalizations.of(context)!.someKey
   used by every screen under ../viewer, ../settings, ../photos
```

None of the generated `app_localizations*.dart` files are committed (see
`../../.gitignore`) — run `flutter gen-l10n` (or `flutter run`/`flutter test`,
which trigger it) after editing either `.arb` file.

# Working in this repo

## Tests come at the end, not during

Don't write or run tests while iterating on a change. Write the code, check
it compiles (`.tools/flutter/bin/flutter analyze lib`), and move on — the
round trip through a test run is the slowest part of a change and most
changes here are reviewed on the phone, not in a test report.

Write and run them **once, at the end**, before building and installing:

```
.tools/flutter/bin/dart format lib test
.tools/flutter/bin/flutter analyze lib test
.tools/flutter/bin/flutter test
.tools/flutter/bin/flutter build ios --release
xcrun devicectl device install app --device <udid> build/ios/iphoneos/Runner.app
```

A batch of changes gets one test pass covering all of it, then the build.
Same before a release.

## Build and install

`flutter install` **uninstalls first**, which deletes the app container and
every local database with it. Use `xcrun devicectl device install app`
instead — it upgrades in place and keeps the data.

## iOS signing

iCloud needs a container registered against this app's App ID; see the
README. Don't add `CODE_SIGN_ENTITLEMENTS` to the Runner target until it
is, or every build fails.

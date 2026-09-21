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
.tools/flutter/bin/flutter build ios --release \
  --obfuscate --split-debug-info=build/symbols
xcrun devicectl device install app --device <udid> build/ios/iphoneos/Runner.app
```

A batch of changes gets one test pass covering all of it, then the build.
Same before a release.

## Physical phone only, never the simulator

Install and run on a real device. Never build for, install to, or launch an
iOS simulator or Android emulator unless explicitly asked — this app is about
the photo library, iCloud and local storage on an actual phone, so a
simulator run proves nothing. If no physical device is connected, stop and
say so rather than falling back to a simulator.

## Build and install

`flutter install` **uninstalls first**, which deletes the app container and
every local database with it. Use `xcrun devicectl device install app`
instead — it upgrades in place and keeps the data.

## iOS signing

iCloud needs a container registered against this app's App ID; see the
README. Don't add `CODE_SIGN_ENTITLEMENTS` to the Runner target until it
is, or every build fails.

## Lightweight and blazing fast, as a hard requirement

This is a gallery. It is held against Photos, which opens instantly and
scrolls at 120fps on the same phone, so "fast enough" is whatever Photos
does — not whatever a Flutter app usually does. A frame dropped while
scrolling the grid is a bug, not a polish item.

**Size budget: 33 MB installed.** Measured baseline (release `Runner.app`,
Sep 2026) is **32.2 MB** — Flutter.framework 10 MB, Dart AOT snapshot
7.6 MB, **SFace.mlmodelc 9.3 MB**, statically linked plugin code 2.6 MB,
app icons 884 KB, no bundled assets.

The budget was 25 MB and the baseline 22.3 until face recognition needed a
model. That was a deliberate call, not a drift: a general image descriptor
could not tell two people apart well enough to be worth the taps, and no
face model small enough to fit the old budget exists under a licence worth
shipping. 9.3 MB buys the difference between "half these faces are wrong"
and a feature. See `docs/design/face-recognition/DESIGN.md`. Everything
else still has to justify its megabyte. The engine is a fixed floor; everything above it is a choice. Check
with `du -sh build/ios/Release-iphoneos/Runner.app` after a release build,
and if a change adds more than a megabyte, justify it or drop it.
`flutter build ios --release --analyze-size` breaks the Dart snapshot down
per package when you need to know *what* grew.

**Always build with `--obfuscate --split-debug-info=build/symbols`** — it
strips Dart symbol names out of the AOT snapshot, worth about 2 MB for
nothing. Keep the emitted symbol files for the release: a crash report from
an obfuscated build is unreadable without them. (It can't be combined with
`--analyze-size`; drop both flags for that one measuring build.)

Two standing rules that came out of getting here, easy to undo by accident:
**decode images through `decodePhoto`**, never `img.decodeImage` — the
latter reaches every decoder in the `image` package and AOT then keeps all
of them; and **nothing goes in `flutter: assets:`** without a reason it has
to be on every phone.

A new dependency is a size and startup cost, and most of them replace code
that would have been shorter than the package's own API surface — see the
`graphview` decision in `docs/design/DESIGN.md`. Prefer writing the forty
lines.

Rules that keep it there:

- **Never decode, resize or encode an image on the main isolate.** All of it
  goes through `Isolate.run`/`compute` (`lib/photos/image_pipeline.dart` is
  pure Dart precisely so it can). The `image` package is pure Dart and slow;
  on the UI isolate it is a freeze.
- **No per-build work proportional to library size.** A getter that filters
  or sorts `_all` is a full pass over the library every time it is read, and
  `build` reads several. Compute derived lists once per `reload()` into
  fields. The library is tens of thousands of records; treat every pass over
  it as expensive.
- **No synchronous file I/O on the UI isolate** — `existsSync`, `lengthSync`,
  `statSync`, `listSync`. One is free; one per record is a stall.
- **No N+1 queries.** A query per album or per person inside a loop is one
  round trip per row. Fetch the memberships in one query and group in Dart.
- **Uploads and downloads stay on the native background transfer**
  (`background_downloader`), never Dart HTTP — see `lib/upload/README.md`.

When something here is knowingly violated, say so at the call site with the
reason and the bound ("best-effort, only sums files already on disk"), so
the next reader knows it was a decision.

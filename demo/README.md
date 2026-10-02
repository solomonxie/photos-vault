# Demo library

Preset data for in-app demo mode. One app, no separate demo build.

- Turn on: bottom of the home page → Demo Mode (instant). Reset Demo, shown there while on, re-seeds it.
- Isolated store: `demo/` subfolders for files and sqlite, `demo.`-prefixed keychain keys, photo library and iCloud Drive off (`lib/demo/demo_mode.dart`). The real library is never touched.
- `seed.json`: photos (scene, date taken, days since added, caption, tags, place, people, albums, backup state, hidden), people, the hidden album (code `1234`, passphrase, notes).
- Photos are drawn at runtime by `lib/demo/demo_images.dart` from `scene` + `id`. No image files, nothing to license, no app-size cost.
- Seeded once by `lib/demo/demo_seed.dart` into the demo store only.
- Credentials (optional): `.env.demo` (gitignored, copy `.env.demo.example`). Passed by every `make` build via `--dart-define-from-file`; read only in demo mode, into the demo keychain.

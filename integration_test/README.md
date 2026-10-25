# Simulator scenarios

The real app on the iOS simulator against a fake S3.

- `scenarios_test.dart` — hide / delete / restore / dates, service level.
- `flows_test.dart` — each multi-step flow through the UI (favourite, bin and recover, permanent delete, declined Photos prompt, Download Full Resolution, albums, tags, upload, Check Now, lost originals, Suggestions, hide and unhide, settings), DB and bucket checked after every step.
- `tour_test.dart` — starts `App` on a seeded library and taps every control on every screen it reaches (`tour_kit.dart`'s crawler), then the hidden album and each album. Fails on any exception or overflow.
- `tour_kit.dart` — shared rig: fakes for the sheets a test can't tap (Photos delete prompt, file picker, share, Safari), an error recorder, the crawler.

Setup:

- Fake S3: `venv/bin/moto_server -H 127.0.0.1 -p 9443 -c srv.pem -k srv.key` (HTTPS; its CA added with `xcrun simctl keychain <sim> add-root-cert`).
- Photos access: `xcrun simctl privacy <sim> grant photos com.solomonxie.photosVault` once before the run.
- Run: `.tools/flutter/bin/flutter test integration_test/<file>.dart -d <sim> --dart-define=PV_S3_ENDPOINT=localhost:9443`
- `TOUR| SHOT <name>` lines in the output are screenshot requests for a host script (`xcrun simctl io <sim> screenshot`); nothing is saved in the app.
- The tests clear the keychain (bucket targets, vault keys) on the simulator.
- Nothing else may drive the same simulator during a run: a backgrounded app stops producing frames and the run stalls.

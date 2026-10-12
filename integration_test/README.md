# Simulator scenarios

Hide / delete / restore / dates against a fake S3, on the iOS simulator.

- Fake S3: `venv/bin/moto_server -H 127.0.0.1 -p 9443 -c srv.pem -k srv.key` (HTTPS; its CA added with `xcrun simctl keychain <sim> add-root-cert`).
- Photos access: `xcrun simctl privacy <sim> grant photos com.solomonxie.photosVault` once before the run.
- Run: `.tools/flutter/bin/flutter test integration_test/scenarios_test.dart -d <sim> --dart-define=PV_S3_ENDPOINT=127.0.0.1:9443`
- The iOS delete prompt can't be tapped from a test; `deleteAssets` is faked to accept or refuse.

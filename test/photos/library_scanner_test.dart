import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/library_scanner.dart';

void main() {
  test('re-reads Photos at most once an interval', () async {
    var scans = 0;
    var now = DateTime(2026, 9, 19, 12);
    final scanner = LibraryScanner(
      scan: () async => scans++,
      interval: const Duration(minutes: 5),
      now: () => now,
    );

    await scanner.run();
    await scanner.run();
    expect(scans, 1, reason: 'still inside the window');

    now = now.add(const Duration(minutes: 5));
    await scanner.run();
    expect(scans, 2);
  });

  test('coming back from Photos re-reads whatever the interval says', () async {
    var scans = 0;
    final now = DateTime(2026, 9, 19, 12);
    final scanner = LibraryScanner(scan: () async => scans++, now: () => now);

    await scanner.run();
    await scanner.run(force: true);

    expect(scans, 2);
  });

  test('a second call joins the pass already running', () async {
    var scans = 0;
    final gate = Completer<void>();
    final scanner = LibraryScanner(
      scan: () async {
        scans++;
        await gate.future;
      },
    );

    final first = scanner.run();
    final second = scanner.run(force: true);
    gate.complete();
    await Future.wait([first, second]);

    expect(scans, 1);
  });

  test(
    'a failed pass is retried rather than waiting out the interval',
    () async {
      var scans = 0;
      final now = DateTime(2026, 9, 19, 12);
      final scanner = LibraryScanner(
        scan: () async {
          scans++;
          throw StateError('no photo library');
        },
        now: () => now,
      );

      await scanner.run();
      await scanner.run();

      expect(scans, 2);
    },
  );
}

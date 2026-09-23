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

  test('the newest photos are read while a full pass is still going', () async {
    var full = 0;
    var recent = 0;
    final gate = Completer<void>();
    final scanner = LibraryScanner(
      scan: () async {
        full++;
        await gate.future;
      },
      scanRecent: () async => recent++,
    );

    final pass = scanner.run();
    await scanner.runRecent();
    await scanner.runRecent();

    expect(recent, 2, reason: 'no interval on the head lane');
    expect(full, 1, reason: 'and it never waits on the full pass');
    gate.complete();
    await pass;
  });

  test('a second head pass joins the one already running', () async {
    var recent = 0;
    final gate = Completer<void>();
    final scanner = LibraryScanner(
      scan: () async {},
      scanRecent: () async {
        recent++;
        await gate.future;
      },
    );

    final first = scanner.runRecent();
    final second = scanner.runRecent();
    gate.complete();
    await Future.wait([first, second]);

    expect(recent, 1);
  });

  test('a head pass that throws is swallowed, not rethrown', () async {
    final scanner = LibraryScanner(
      scan: () async {},
      scanRecent: () async => throw StateError('no photo library'),
    );

    await expectLater(scanner.runRecent(), completes);
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

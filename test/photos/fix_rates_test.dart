import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/fix_rates.dart';

import '../support/fake_asset_record_store.dart';

void main() {
  Duration video(FixRates r, int bytes) => r.estimate(
    'optimize:video',
    bySize: true,
    bytes: bytes,
    items: 1,
    perItem: Duration.zero,
    bytesPerSecond: 10e6,
  );

  test('a guess until timed, then this phone\'s own rate, kept across '
      'launches', () async {
    final store = FakeAssetRecordStore();
    final rates = FixRates(store);
    await rates.load();
    expect(video(rates, 100000000), const Duration(seconds: 10));

    for (var i = 0; i < 3; i++) {
      await rates.record(
        'optimize:video',
        took: const Duration(seconds: 20),
        bytes: 100000000,
        items: 1,
      );
    }
    expect(video(rates, 100000000), const Duration(seconds: 20));

    final relaunched = FixRates(store);
    await relaunched.load();
    expect(video(relaunched, 50000000), const Duration(seconds: 10));
  });

  test('a rename is timed per item, whatever its size', () async {
    final rates = FixRates(FakeAssetRecordStore());
    await rates.record(
      'rename',
      took: const Duration(seconds: 3),
      bytes: 999999999,
      items: 3,
    );
    expect(
      rates.estimate(
        'rename',
        bySize: false,
        bytes: 1,
        items: 10,
        perItem: const Duration(milliseconds: 300),
        bytesPerSecond: 1,
      ),
      const Duration(seconds: 10),
    );
  });
}

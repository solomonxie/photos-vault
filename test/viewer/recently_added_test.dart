import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/built_in_album.dart';
import 'package:photos_vault/viewer/photo_grid_layout.dart';

AssetRecord _record(String id, {required DateTime taken, DateTime? added}) =>
    AssetRecord(
      localId: id,
      contentHash: id,
      platform: 'ios',
      createdAt: taken,
      updatedAt: taken,
      addedAt: added,
    );

void main() {
  final now = DateTime(2026, 10, 1, 12);

  test('an old photo imported today is recently added', () {
    final old = _record(
      'old',
      taken: DateTime(2019, 7, 4),
      added: now.subtract(const Duration(hours: 1)),
    );
    final week = _record(
      'week',
      taken: DateTime(2026, 9, 24),
      added: now.subtract(const Duration(days: 7)),
    );
    final stale = _record(
      'stale',
      taken: DateTime(2026, 9, 1),
      added: now.subtract(const Duration(days: 40)),
    );

    final recent = recentlyAdded([old, week, stale], now);

    expect(recent.map((r) => r.localId), ['week', 'old']);
  });

  test('no recorded arrival reads as the photo\'s own date', () {
    final legacy = _record('legacy', taken: DateTime(2026, 9, 30));
    expect(legacy.addedAt, legacy.createdAt);
  });

  test('Recently Added groups its days by arrival', () {
    final records = [
      _record('a', taken: DateTime(2019), added: DateTime(2026, 9, 30, 9)),
      _record('b', taken: DateTime(2024), added: DateTime(2026, 9, 30, 10)),
    ];

    final byTaken = PhotoGridLayout.of(records: records, width: 390);
    final byAdded = PhotoGridLayout.of(
      records: records,
      width: 390,
      dateOf: PhotoGridLayout.addedAt,
    );

    expect(byTaken.sections, hasLength(2));
    expect(byAdded.sections.single.day, DateTime(2026, 9, 30));
  });
}

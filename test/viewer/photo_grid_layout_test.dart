import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:bring_your_own_photos/viewer/photo_grid_layout.dart';
import 'package:flutter_test/flutter_test.dart';

AssetRecord _record(String id, DateTime createdAt) => AssetRecord(
  localId: id,
  contentHash: id,
  platform: 'test',
  createdAt: createdAt,
  updatedAt: createdAt,
);

/// Oldest-first, `count` per day starting at [start].
List<AssetRecord> _days(DateTime start, int days, int perDay) => [
  for (var d = 0; d < days; d++)
    for (var i = 0; i < perDay; i++)
      _record('a$d-$i', start.add(Duration(days: d, hours: 1 + i % 12))),
];

void main() {
  // 3 columns, 8pt gaps and 8pt side padding in a 400pt-wide viewport:
  // tiles are depending-on-nothing named numbers below.
  PhotoGridLayout layoutOf(List<AssetRecord> records) =>
      PhotoGridLayout.of(records: records, width: 400, headerExtent: 44);

  group('sections', () {
    test('groups by calendar day, in the order given', () {
      final layout = layoutOf(_days(DateTime(2020, 1, 1), 3, 2));

      expect(layout.sections.map((s) => s.day), [
        DateTime(2020, 1, 1),
        DateTime(2020, 1, 2),
        DateTime(2020, 1, 3),
      ]);
      expect(layout.sections.map((s) => s.recordCount), [2, 2, 2]);
    });

    test('a day of 7 photos is a header plus 3 rows of 3 columns', () {
      final layout = layoutOf(_days(DateTime(2020, 1, 1), 1, 7));

      expect(layout.sections.single.rowCount, 4);
      expect(layout.rowCount, 4);
      expect(layout.rowAt(0).isHeader, isTrue);
      expect(layout.rowAt(1).recordCount, 3);
      expect(layout.rowAt(3).recordCount, 1, reason: 'last row is a remainder');
      expect(layout.rowAt(3).firstRecord, 6);
    });

    test('is empty for no records', () {
      final layout = layoutOf(const []);

      expect(layout.isEmpty, isTrue);
      expect(layout.totalExtent, 0);
      expect(layout.dayAtOffset(100), isNull);
    });
  });

  group('offsets', () {
    test('rows tile the whole extent without gaps or overlap', () {
      final layout = layoutOf(_days(DateTime(2020, 1, 1), 5, 4));

      var offset = 0.0;
      for (var row = 0; row < layout.rowCount; row++) {
        expect(layout.offsetOfRow(row), closeTo(offset, 0.001));
        offset += layout.extentOfRow(row);
      }
      expect(offset, closeTo(layout.totalExtent, 0.001));
    });

    test('offsetOfRow past the end is the total extent', () {
      final layout = layoutOf(_days(DateTime(2020, 1, 1), 2, 2));

      expect(layout.offsetOfRow(layout.rowCount), layout.totalExtent);
    });

    test('rowAtOffset finds the row containing an offset', () {
      final layout = layoutOf(_days(DateTime(2020, 1, 1), 4, 5));

      for (var row = 0; row < layout.rowCount; row++) {
        final start = layout.offsetOfRow(row);
        expect(layout.rowAtOffset(start), row);
        expect(layout.rowAtOffset(start + layout.extentOfRow(row) / 2), row);
      }
    });

    test('rowAtOffset clamps outside the grid', () {
      final layout = layoutOf(_days(DateTime(2020, 1, 1), 2, 2));

      expect(layout.rowAtOffset(-500), 0);
      expect(layout.rowAtOffset(layout.totalExtent + 500), layout.rowCount - 1);
    });

    test('lastRowBefore excludes a row starting exactly at the offset', () {
      final layout = layoutOf(_days(DateTime(2020, 1, 1), 3, 3));

      expect(layout.lastRowBefore(layout.offsetOfRow(2)), 1);
      expect(layout.lastRowBefore(layout.offsetOfRow(2) + 1), 2);
    });
  });

  group('dates', () {
    test('dayAtOffset reports the day drawn at a scroll offset', () {
      final records = _days(DateTime(2020, 1, 1), 3, 3);
      final layout = layoutOf(records);

      expect(layout.dayAtOffset(0), DateTime(2020, 1, 1));
      expect(
        layout.dayAtOffset(layout.sections[1].offset + 10),
        DateTime(2020, 1, 2),
      );
      expect(
        layout.dayAtOffset(layout.totalExtent + 1000),
        DateTime(2020, 1, 3),
        reason: 'past the end still reads as the newest day',
      );
    });

    test('offsetOfDay lands on the first section on or after that day', () {
      final layout = layoutOf([
        _record('a', DateTime(2019, 5, 4)),
        _record('b', DateTime(2021, 8, 9)),
      ]);

      expect(layout.offsetOfDay(DateTime(2019, 5, 4)), 0);
      expect(
        layout.offsetOfDay(DateTime(2020, 1, 1)),
        layout.sections[1].offset,
      );
      expect(layout.offsetOfDay(DateTime(2030, 1, 1)), layout.totalExtent);
    });
  });

  test('a decade-sized library resolves lookups without walking it', () {
    // ~110k photos over 10 years — the case the whole flat-row model
    // exists for. A linear scan per lookup would make this crawl.
    final records = _days(DateTime(2015, 1, 1), 3650, 30);
    final layout = PhotoGridLayout.of(records: records, width: 400);

    expect(layout.sections, hasLength(3650));
    expect(layout.records, hasLength(109500));

    final stopwatch = Stopwatch()..start();
    for (var i = 0; i < 20000; i++) {
      final offset = layout.totalExtent * (i % 1000) / 1000;
      layout.rowAt(layout.rowAtOffset(offset));
      layout.dayAtOffset(offset);
    }
    stopwatch.stop();

    expect(
      stopwatch.elapsedMilliseconds,
      lessThan(2000),
      reason: '20k lookups over 110k photos should be binary searches',
    );
    expect(layout.dayAtOffset(layout.totalExtent), DateTime(2024, 12, 28));
  });
}

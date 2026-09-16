import 'dart:math' as math;

import '../storage/asset_record.dart';

/// One day of the grid: its header row plus the tile rows under it.
class PhotoGridSection {
  const PhotoGridSection({
    required this.day,
    required this.firstRecord,
    required this.recordCount,
    required this.firstRow,
    required this.rowCount,
    required this.offset,
    required this.extent,
  });

  /// Midnight of the day these records fall on.
  final DateTime day;
  final int firstRecord;
  final int recordCount;

  /// Index of this section's header in the flat row list; its tile rows are
  /// `firstRow + 1 .. firstRow + rowCount - 1`.
  final int firstRow;
  final int rowCount;
  final double offset;
  final double extent;

  int get tileRowCount => rowCount - 1;
}

/// What a flat row index resolves to — the day header, or a run of tiles.
class PhotoGridRow {
  const PhotoGridRow.header(this.section)
    : firstRecord = -1,
      recordCount = 0,
      isHeader = true;
  const PhotoGridRow.tiles(this.section, this.firstRecord, this.recordCount)
    : isHeader = false;

  final int section;
  final int firstRecord;
  final int recordCount;
  final bool isHeader;
}

/// Geometry for a day-grouped photo grid, flattened to one list of
/// fixed-height rows.
///
/// A library of a hundred thousand photos is ~35k rows across ~4k days —
/// far too many to give each day its own sliver, and too many to walk
/// linearly per frame. Every lookup here is O(log sections) off a
/// precomputed per-section offset, which is what lets the grid render as a
/// single sliver, jump straight to the newest photo, and answer "what month
/// is at this scroll offset?" for the scrubber.
///
/// [records] must be sorted oldest-first — the grid reads bottom-newest,
/// like Photos.
class PhotoGridLayout {
  PhotoGridLayout._({
    required this.records,
    required this.sections,
    required this.crossAxisCount,
    required this.tileExtent,
    required this.spacing,
    required this.horizontalPadding,
    required this.headerExtent,
    required this.rowExtent,
    required this.rowCount,
    required this.totalExtent,
  });

  factory PhotoGridLayout.of({
    required List<AssetRecord> records,
    required double width,
    int crossAxisCount = 3,
    double spacing = 8,
    double horizontalPadding = 8,
    double headerExtent = 44,
  }) {
    final columns = math.max(1, crossAxisCount);
    final tileExtent = math.max(
      1.0,
      (width - 2 * horizontalPadding - (columns - 1) * spacing) / columns,
    );
    final rowExtent = tileExtent + spacing;

    final sections = <PhotoGridSection>[];
    var offset = 0.0;
    var row = 0;
    var i = 0;
    while (i < records.length) {
      final day = _midnight(records[i].createdAt);
      var end = i;
      while (end < records.length && _midnight(records[end].createdAt) == day) {
        end++;
      }
      final count = end - i;
      final tileRows = (count + columns - 1) ~/ columns;
      final extent = headerExtent + tileRows * rowExtent;
      sections.add(
        PhotoGridSection(
          day: day,
          firstRecord: i,
          recordCount: count,
          firstRow: row,
          rowCount: tileRows + 1,
          offset: offset,
          extent: extent,
        ),
      );
      offset += extent;
      row += tileRows + 1;
      i = end;
    }

    return PhotoGridLayout._(
      records: records,
      sections: sections,
      crossAxisCount: columns,
      tileExtent: tileExtent,
      spacing: spacing,
      horizontalPadding: horizontalPadding,
      headerExtent: headerExtent,
      rowExtent: rowExtent,
      rowCount: row,
      totalExtent: offset,
    );
  }

  final List<AssetRecord> records;
  final List<PhotoGridSection> sections;
  final int crossAxisCount;
  final double tileExtent;
  final double spacing;
  final double horizontalPadding;
  final double headerExtent;

  /// A tile row's full height — the tiles plus the gap under them.
  final double rowExtent;
  final int rowCount;
  final double totalExtent;

  bool get isEmpty => rowCount == 0;

  static DateTime _midnight(DateTime dt) {
    final local = dt.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  /// Largest section index whose [PhotoGridSection.firstRow] is `<= row`.
  int sectionOfRow(int row) {
    if (sections.isEmpty) return -1;
    var lo = 0;
    var hi = sections.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (sections[mid].firstRow <= row) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Largest section index whose [PhotoGridSection.offset] is `<= offset`.
  int sectionAtOffset(double offset) {
    if (sections.isEmpty) return -1;
    var lo = 0;
    var hi = sections.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (sections[mid].offset <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  PhotoGridRow rowAt(int row) {
    final sectionIndex = sectionOfRow(row);
    final s = sections[sectionIndex];
    if (row == s.firstRow) return PhotoGridRow.header(sectionIndex);
    final tileRow = row - s.firstRow - 1;
    final first = s.firstRecord + tileRow * crossAxisCount;
    final remaining = s.firstRecord + s.recordCount - first;
    return PhotoGridRow.tiles(
      sectionIndex,
      first,
      math.min(crossAxisCount, remaining),
    );
  }

  double extentOfRow(int row) {
    if (row < 0 || row >= rowCount) return 0;
    return sections[sectionOfRow(row)].firstRow == row
        ? headerExtent
        : rowExtent;
  }

  double offsetOfRow(int row) {
    if (row <= 0) return 0;
    if (row >= rowCount) return totalExtent;
    final s = sections[sectionOfRow(row)];
    if (row == s.firstRow) return s.offset;
    return s.offset + headerExtent + (row - s.firstRow - 1) * rowExtent;
  }

  /// The row drawn at [offset] — the first row when above the grid, the
  /// last when past its end.
  int rowAtOffset(double offset) {
    if (rowCount == 0) return 0;
    if (offset <= 0) return 0;
    if (offset >= totalExtent) return rowCount - 1;
    final index = sectionAtOffset(offset);
    final s = sections[index];
    final within = offset - s.offset;
    if (within < headerExtent) return s.firstRow;
    // Nudged before flooring: `within` is a difference of accumulated
    // doubles, so a row's own start offset can land a hair under its true
    // value and read as the row above it.
    final tileRow = ((within - headerExtent) / rowExtent + 1e-9).floor();
    return math.min(s.firstRow + 1 + tileRow, s.firstRow + s.rowCount - 1);
  }

  /// The last row that starts strictly before [offset] — the trailing edge
  /// of a viewport ending there, so a row starting exactly at [offset]
  /// isn't counted as visible.
  int lastRowBefore(double offset) {
    if (rowCount == 0) return 0;
    final row = rowAtOffset(offset);
    if (row > 0 && offsetOfRow(row) >= offset) return row - 1;
    return row;
  }

  /// Section holding the record at [index] — binary search, same as
  /// everything else here.
  int sectionOfRecord(int index) {
    if (sections.isEmpty) return -1;
    var lo = 0;
    var hi = sections.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (sections[mid].firstRecord <= index) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The tile row a record is drawn on.
  int rowOfRecord(int index) {
    final s = sections[sectionOfRecord(index)];
    return s.firstRow + 1 + (index - s.firstRecord) ~/ crossAxisCount;
  }

  /// First record taken on or after [day] — how a scroll position survives
  /// the library growing underneath it: the photo the viewport was resting
  /// on is found again by *when it was taken*, which doesn't change when
  /// older photos arrive above it.
  ///
  /// Returns [records.length] when everything is older than [day].
  int indexOnOrAfter(DateTime day) {
    var lo = 0;
    var hi = records.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (records[mid].createdAt.isBefore(day)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The day shown at [offset] — what the scrubber labels itself with.
  DateTime? dayAtOffset(double offset) {
    if (sections.isEmpty) return null;
    return sections[sectionAtOffset(offset.clamp(0, totalExtent))].day;
  }

  /// Scroll offset that puts [day]'s section header at the top — used to
  /// jump the grid to a year/month picked on the scrubber.
  double offsetOfDay(DateTime day) {
    final target = _midnight(day);
    for (final s in sections) {
      if (!s.day.isBefore(target)) return s.offset;
    }
    return totalExtent;
  }
}

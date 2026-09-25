import 'package:photos_vault/backup/snapshot_archive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the copy taken before a deletion sorts after every daily one', () {
    final name = preDeletionArchiveName(DateTime(2026, 9, 18, 14, 32, 7));

    expect(name, '99999999-pre-deletion-20260918-143207.zip');
    expect([dailyArchiveName(DateTime(2026, 12, 31)), name]..sort(), [
      '20261231.zip',
      name,
    ]);
  });

  test('a copy an older build wrote is still one of ours', () {
    // Renaming it forward must not orphan what is already in somebody's
    // iCloud Drive or bucket: it is still found, still counted when
    // pruning, and still the newest thing there.
    expect(
      isSnapshotArchiveName('99999999-before-removal-20260918-143207.zip'),
      isTrue,
    );
    expect(
      isSnapshotArchiveName('99999999-pre-deletion-20260918-143207.zip'),
      isTrue,
    );
    expect(isSnapshotArchiveName('99999999-pre-deletion-nope.zip'), isFalse);
  });
}

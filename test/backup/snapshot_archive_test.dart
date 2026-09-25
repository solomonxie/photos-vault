import 'package:photos_vault/backup/snapshot_archive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the copy taken before a deletion leads with when it was taken', () {
    expect(
      preDeletionArchiveName(DateTime(2026, 9, 18, 14, 32, 7)),
      '20260918-143207-pre-deletion-photos-vault.zip',
    );
  });

  test('a final copy is restored from over a newer daily one', () {
    // Emptying the library makes the next daily backup empty too. Sorting
    // by date would hand that one back on a fresh install; the rule is
    // what it was, the sentinel that used to encode it is not.
    expect(
      latestArchiveName([
        '20260918.zip',
        '20260919-101500-pre-deletion-photos-vault.zip',
        '20260920.zip',
      ]),
      '20260919-101500-pre-deletion-photos-vault.zip',
    );
  });

  test('the newest final copy wins, whichever build named it', () {
    expect(
      latestArchiveName([
        '99999999-before-removal-20260101-000000.zip',
        '20260919-101500-pre-deletion-photos-vault.zip',
        '99999999-pre-deletion-20260301-000000.zip',
      ]),
      '20260919-101500-pre-deletion-photos-vault.zip',
    );
  });

  test('dates decide when there is no final copy, and null when none', () {
    expect(
      latestArchiveName(['202609.zip', '20260918.zip', 'holiday.zip']),
      '20260918.zip',
    );
    expect(latestArchiveName(const ['holiday.zip']), isNull);
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
    expect(
      isSnapshotArchiveName('20260918-143207-pre-deletion-photos-vault.zip'),
      isTrue,
    );
  });
}

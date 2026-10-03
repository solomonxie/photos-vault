import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/upload/bucket_import.dart';

void main() {
  test('takenAt reads the camera timestamp from the name', () {
    expect(
      BucketImport.takenAt('import_20251228120340_179792A.mp4'),
      DateTime(2025, 12, 28, 12, 3, 40),
    );
  });

  test('takenAt is null when the name has no timestamp', () {
    expect(BucketImport.takenAt('holiday.mp4'), isNull);
    expect(BucketImport.takenAt('import_99999999999999.mp4'), isNull);
  });
}

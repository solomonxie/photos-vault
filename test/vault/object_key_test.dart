import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/backup_coordinator.dart';
import 'package:photos_vault/vault/object_key.dart';

AssetRecord _record({required String localId, bool isVideo = false}) =>
    AssetRecord(
      localId: localId,
      contentHash: 'h',
      platform: 'ios',
      sourceType: AssetSourceType.photoManager,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      isVideo: isVideo,
      derivatives: const {},
    );

void main() {
  test('a carrier is named the same by both sides', () {
    // `vaultCarrierKey` works the name out from the record alone, because
    // with no bucket configured there is no destination key to read. It has
    // to agree with what `BackupCoordinator` really uploads, or a carrier is
    // filed under one name and looked for under another.
    final record = _record(localId: 'photo:B84E8479-475C/L0/001');

    expect(
      vaultCarrierKey(record),
      'originals/${BackupCoordinator.safeFileName(record, 'carrier.jpg')}',
    );
  });

  test('a video carrier keeps the .mov the builder writes', () {
    final record = _record(localId: 'photo:1', isVideo: true);

    expect(
      vaultCarrierKey(record),
      'originals/${BackupCoordinator.safeFileName(record, 'carrier.mov')}',
    );
  });

  test('a Live Photo names its two halves apart', () {
    final record = _record(localId: 'photo:1');

    expect(vaultCarrierKey(record), 'originals/photo_1.jpg');
    expect(vaultLiveCarrierKey(record), 'originals/photo_1.mov');
  });

  test('the key carries no bucket prefix', () {
    // A key with a prefix in it ties the index to one bucket, and ties a
    // hidden photo's existence to having a bucket at all.
    expect(vaultCarrierKey(_record(localId: 'a')), startsWith('originals/'));
  });

  test('anything a filesystem or a URL would choke on is replaced', () {
    expect(
      vaultSafeName('photo:B84E8479/L0/001 (2).HEIC'),
      'photo_B84E8479_L0_001__2_.HEIC',
    );
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/upload/backup_coordinator.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/object_key.dart';

AssetRecord _record({required String localId, bool isVideo = false}) =>
    AssetRecord(
      localId: localId,
      contentHash: 'h',
      platform: 'ios',
      sourceType: AssetSourceType.photoManager,
      createdAt: DateTime(2026, 3, 4, 5, 6, 7),
      updatedAt: DateTime(2026),
      isVideo: isVideo,
      derivatives: const {},
    );

CarrierKeys _keys(int seed) => CarrierKeys.forAlbum(
  Uint8List.fromList(List.generate(32, (i) => (i * seed) % 251)),
);

void main() {
  final keys = _keys(3);

  test('a carrier is named the same by both sides', () {
    final record = _record(localId: 'photo:B84E8479-475C/L0/001');
    final built = '${hiddenBaseName(keys, record)}.jpg';

    expect(vaultCarrierKey(record, keys), 'originals/$built');
    expect(
      BackupCoordinator.safeFileName(record, '/tmp/$built'),
      built,
      reason: 'the coordinator keeps the name the builder gave the file',
    );
  });

  test('a video carrier keeps the .mov the builder writes', () {
    final record = _record(localId: 'photo:1', isVideo: true);

    expect(vaultCarrierKey(record, keys), endsWith('.mov'));
  });

  test('a Live Photo names its two halves apart', () {
    final record = _record(localId: 'photo:1');
    final still = vaultCarrierKey(record, keys);
    final motion = vaultLiveCarrierKey(record, keys);

    expect(still, endsWith('.jpg'));
    expect(motion, endsWith('.mov'));
    expect(
      still.substring(0, still.length - 4),
      motion.substring(0, motion.length - 4),
    );
  });

  test('the key carries no bucket prefix', () {
    expect(
      vaultCarrierKey(_record(localId: 'a'), keys),
      startsWith('originals/'),
    );
  });

  test('a hidden name is worked out the same every time', () {
    final record = _record(localId: 'photo:1');

    expect(hiddenBaseName(keys, record), hiddenBaseName(keys, record));
    expect(
      hiddenBaseName(keys, record),
      isNot(hiddenBaseName(keys, _record(localId: 'photo:2'))),
    );
  });

  group('protocol names', () {
    test('an ordinary name fits and carries the photo date', () {
      final name = ordinaryBaseName(_record(localId: 'photo:1'));

      expect(name, startsWith('20260304050607_'));
      expect(fitsProtocol('$name.webp'), isTrue);
      expect(parseProtocolName('$name.webp')!.stamp, '20260304050607');
    });

    test('old names do not fit', () {
      expect(fitsProtocol('photo_B84E8479_L0_001.webp'), isFalse);
      expect(fitsProtocol('import_20251228120340_179792A.mp4'), isFalse);
    });

    test('an album recognises its own names, and only its own', () {
      final name = '${hiddenBaseName(keys, _record(localId: 'photo:1'))}.jpg';

      expect(fitsProtocol(name), isTrue);
      expect(nameBelongsTo(name, keys.macKey), isTrue);
      expect(nameBelongsTo(name, _keys(5).macKey), isFalse);
    });

    test('an ordinary name belongs to no album', () {
      final name = '${ordinaryBaseName(_record(localId: 'photo:1'))}.webp';

      expect(nameBelongsTo(name, keys.macKey), isFalse);
    });

    test('hidden names do not repeat anything between photos', () {
      final a = hiddenBaseName(keys, _record(localId: 'photo:1')).split('_');
      final b = hiddenBaseName(keys, _record(localId: 'photo:2')).split('_');

      expect(a.last.substring(0, 8), isNot(b.last.substring(0, 8)));
      expect(a.last.substring(16), isNot(b.last.substring(16)));
    });

    test('the name a header asks for is one its album recognises', () {
      final nonce = hiddenNonce(keys, _record(localId: 'photo:1'));
      final header = CarrierHeader(
        masterSalt: Uint8List(16),
        ivThumb: Uint8List(16),
        ivFull: Uint8List(16),
        thumbLength: 1,
        originalLength: 1,
        extension: 'jpg',
        nonce: nonce,
      );
      final stored = CarrierHeader.parse(header.toBytes(keys.macKey))!;
      final name = '${hiddenBaseNameFromHeader(DateTime(2020), stored)}.jpg';

      expect(nameBelongsTo(name, keys.macKey), isTrue);
    });
  });

  test('anything a filesystem or a URL would choke on is replaced', () {
    expect(
      vaultSafeName('photo:B84E8479/L0/001 (2).HEIC'),
      'photo_B84E8479_L0_001__2_.HEIC',
    );
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/jpeg_segments.dart';
import 'package:photos_vault/vault/mp4_boxes.dart';

import 'carrier_fixtures.dart';

void main() {
  final cipher = PlatformCipher();
  final keys = CarrierKeys.forAlbum(
    Uint8List.fromList(List.generate(32, (i) => i)),
  );
  final otherKeys = CarrierKeys.forAlbum(
    Uint8List.fromList(List.generate(32, (i) => 32 - i)),
  );
  final masterSalt = Uint8List.fromList(List.generate(16, (i) => i * 3));
  final thumbnail = Uint8List.fromList(List.generate(25000, (i) => i % 251));
  final original = Uint8List.fromList(
    List.generate(2 * 1024 * 1024, (i) => (i * 7) % 253),
  );

  group('jpeg carrier', () {
    late Uint8List carrier;

    setUp(() {
      carrier = buildJpegCarrier(
        cipher: cipher,
        keys: keys,
        masterSalt: masterSalt,
        decoy: decoyJpeg(),
        thumbnail: thumbnail,
        original: original,
        extension: 'heic',
      )!;
    });

    test('still decodes as an image of the decoy dimensions', () {
      final decoded = img.decodeJpg(carrier);
      expect(decoded, isNotNull);
      expect(decoded!.width, 640);
      expect(decoded.height, 480);
    });

    test('has nothing past EOI', () {
      expect(carrier[carrier.length - 2], 0xFF);
      expect(carrier.last, 0xD9);
    });

    test('round trips the original and its extension', () {
      final opened = openCarrier(
        cipher: cipher,
        keys: keys,
        payload: payloadOf(carrier)!,
      );
      expect(opened, isNotNull);
      expect(opened!.extension, 'heic');
      expect(opened.original, equals(original));
    });

    test('the first 64 KB is enough for the thumbnail', () {
      final prefix = Uint8List.sublistView(carrier, 0, thumbnailPrefixBytes);
      final opened = openThumbnail(
        cipher: cipher,
        keys: keys,
        payloadPrefix: carrierPayloadFromPrefix(prefix),
      );
      expect(opened, equals(thumbnail));
    });

    test('another album key opens nothing, and says so quietly', () {
      final payload = payloadOf(carrier)!;
      expect(
        openCarrier(cipher: cipher, keys: otherKeys, payload: payload),
        isNull,
      );
      expect(
        openThumbnail(cipher: cipher, keys: otherKeys, payloadPrefix: payload),
        isNull,
      );
    });

    test('a changed byte fails the MAC', () {
      final payload = payloadOf(carrier)!;
      payload[payload.length - 100] ^= 0xFF;
      expect(openCarrier(cipher: cipher, keys: keys, payload: payload), isNull);
    });

    test('an ordinary photo has no payload at all', () {
      expect(payloadOf(decoyJpeg()), isNull);
    });

    test('two carriers of the same photo share no bytes to group them by', () {
      final again = buildJpegCarrier(
        cipher: cipher,
        keys: keys,
        masterSalt: masterSalt,
        decoy: decoyJpeg(),
        thumbnail: thumbnail,
        original: original,
        extension: 'heic',
      )!;
      final a = payloadOf(carrier)!;
      final b = payloadOf(again)!;
      // The locator is keyed to the file, not the album.
      expect(
        Uint8List.sublistView(a, headerBytes - 4, headerBytes),
        isNot(equals(Uint8List.sublistView(b, headerBytes - 4, headerBytes))),
      );
      expect(a, isNot(equals(b)));
    });
  });

  group('mp4 carrier', () {
    test('round trips, stays parseable, and keeps the decoy first', () {
      final decoy = decoyMp4();
      final carrier = buildMp4Carrier(
        cipher: cipher,
        keys: keys,
        masterSalt: masterSalt,
        decoy: decoy,
        poster: thumbnail,
        original: original,
        extension: 'mov',
      )!;

      expect(
        Uint8List.sublistView(carrier, 0, decoy.length),
        equals(decoy),
        reason: 'no sample offset in the decoy may move',
      );
      final boxes = parseMp4Boxes(carrier);
      expect(boxes, isNotNull);
      expect(boxes!.map((b) => b.type), containsAllInOrder(['ftyp', 'free']));

      final opened = openCarrier(
        cipher: cipher,
        keys: keys,
        payload: payloadOf(carrier)!,
      );
      expect(opened!.original, equals(original));
      expect(opened.extension, 'mov');
    });

    test('an ordinary video has no payload', () {
      expect(payloadOf(decoyMp4()), isNull);
    });
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/carrier_probe.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/jpeg_segments.dart';
import 'package:photos_vault/vault/keys.dart';

import 'carrier_fixtures.dart';

RangeReader _reader(Uint8List bytes) =>
    (start, end) async => Uint8List.sublistView(
      bytes,
      start,
      end > bytes.length ? bytes.length : end,
    );

void main() {
  final cipher = PlatformCipher();
  final keys = CarrierKeys.forAlbum(
    Uint8List.fromList(List.generate(32, (i) => i)),
  );
  final other = CarrierKeys.forAlbum(
    Uint8List.fromList(List.generate(32, (i) => 32 - i)),
  );
  final salt = Uint8List.fromList(List.generate(16, (i) => i * 3));
  final nonce = Uint8List.fromList(List.generate(8, (i) => i + 1));
  final thumbnail = Uint8List.fromList(List.generate(20000, (i) => i % 251));
  final original = Uint8List.fromList(
    List.generate(300 * 1024, (i) => (i * 7) % 253),
  );
  final meta = CarrierMeta(
    takenAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    width: 4032,
    height: 3024,
    isVideo: false,
  );

  Uint8List jpegCarrier() => buildJpegCarrier(
    cipher: cipher,
    keys: keys,
    masterSalt: salt,
    decoy: decoyJpeg(),
    thumbnail: thumbnail,
    original: original,
    extension: 'heic',
    nonce: nonce,
    meta: meta,
  )!;

  group('v2 jpeg carrier', () {
    test('opens to the original with the right key', () {
      final opened = openCarrier(
        cipher: cipher,
        keys: keys,
        payload: payloadOf(jpegCarrier())!,
      );

      expect(opened!.original, original);
      expect(opened.extension, 'heic');
    });

    test('the thumbnail comes back without the metadata in front', () {
      final prefix = jpegCarrier().sublist(0, 64 * 1024);

      expect(
        openThumbnail(
          cipher: cipher,
          keys: keys,
          payloadPrefix: carrierPayloadFromPrefix(prefix),
        ),
        thumbnail,
      );
    });

    test('the first 64 KB say when, how big and what kind', () {
      final prefix = jpegCarrier().sublist(0, 64 * 1024);
      final read = openMeta(
        cipher: cipher,
        keys: keys,
        payloadPrefix: carrierPayloadFromPrefix(prefix),
      )!;

      expect(read.takenAt, meta.takenAt);
      expect(read.width, 4032);
      expect(read.height, 3024);
      expect(read.isVideo, isFalse);
    });

    test('another album opens none of it', () {
      final payload = payloadOf(jpegCarrier())!;

      expect(
        openCarrier(cipher: cipher, keys: other, payload: payload),
        isNull,
      );
      expect(
        openMeta(cipher: cipher, keys: other, payloadPrefix: payload),
        isNull,
      );
    });

    test('the header holds the nonce and a locator only its album checks', () {
      final header = CarrierHeader.parse(payloadOf(jpegCarrier())!)!;

      expect(header.isV2, isTrue);
      expect(header.nonce, nonce);
      expect(headerBelongsTo(header, keys.macKey), isTrue);
      expect(headerBelongsTo(header, other.macKey), isFalse);
    });

    test('a v1 carrier still opens, and has no metadata', () {
      final v1 = buildJpegCarrier(
        cipher: cipher,
        keys: keys,
        masterSalt: salt,
        decoy: decoyJpeg(),
        thumbnail: thumbnail,
        original: original,
        extension: 'heic',
      )!;
      final payload = payloadOf(v1)!;

      expect(
        openCarrier(cipher: cipher, keys: keys, payload: payload)!.original,
        original,
      );
      expect(
        openMeta(cipher: cipher, keys: keys, payloadPrefix: payload),
        isNull,
      );
      expect(CarrierHeader.parse(payload)!.isV2, isFalse);
    });
  });

  group('probe', () {
    const probe = CarrierProbe();

    test('finds a jpeg carrier from its first 64 KB', () async {
      final bytes = jpegCarrier();
      final found = await probe.probe(
        read: _reader(bytes),
        size: bytes.length,
        isVideo: false,
      );

      expect(found, isNotNull);
      expect(headerBelongsTo(found!.header, keys.macKey), isTrue);
    });

    test('finds an mp4 carrier by walking its boxes', () async {
      final bytes = buildMp4Carrier(
        cipher: cipher,
        keys: keys,
        masterSalt: salt,
        decoy: decoyMp4(),
        poster: thumbnail,
        original: original,
        extension: 'mov',
        nonce: nonce,
        meta: CarrierMeta(
          takenAt: meta.takenAt,
          width: 1920,
          height: 1080,
          isVideo: true,
        ),
      )!;
      var reads = 0;
      Future<Uint8List?> counting(int start, int end) {
        reads++;
        return _reader(bytes)(start, end);
      }

      final found = await probe.probe(
        read: counting,
        size: bytes.length,
        isVideo: true,
      );

      expect(found, isNotNull);
      expect(reads, lessThan(12), reason: 'a handful of tiny reads');
      expect(
        openMeta(
          cipher: cipher,
          keys: keys,
          payloadPrefix: found!.payloadPrefix,
        )!.isVideo,
        isTrue,
      );
    });

    test('an ordinary jpeg and an ordinary mp4 are not carriers', () async {
      final jpeg = decoyJpeg();
      final mp4 = decoyMp4();

      expect(
        await probe.probe(
          read: _reader(jpeg),
          size: jpeg.length,
          isVideo: false,
        ),
        isNull,
      );
      expect(
        await probe.probe(read: _reader(mp4), size: mp4.length, isVideo: true),
        isNull,
      );
    });

    test('stray APP7 data that is not a header stays ordinary', () async {
      final parts = parseJpeg(decoyJpeg())!;
      final junk = writeJpegWithPayload(
        parts,
        Uint8List.fromList([9, 9, 9, 9]),
      );

      expect(
        await probe.probe(
          read: _reader(junk),
          size: junk.length,
          isVideo: false,
        ),
        isNull,
      );
    });
  });

  test('a salt on the list is ours, any other is foreign', () {
    final header = CarrierHeader.parse(payloadOf(jpegCarrier())!)!;
    PassphraseEntry entry(Uint8List s) =>
        PassphraseEntry(id: 'e', salt: s, verifier: Uint8List(32), hint: '');

    expect(isKnownSalt(header, [entry(salt)]), isTrue);
    expect(isKnownSalt(header, [entry(Uint8List(16))]), isFalse);
    expect(isKnownSalt(header, const []), isFalse);
  });
}

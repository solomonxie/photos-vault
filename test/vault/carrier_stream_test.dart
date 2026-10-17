import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/carrier_stream.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/jpeg_segments.dart';

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
  // Past two chunks, and not a block multiple: every boundary is crossed.
  final original = Uint8List.fromList(
    List.generate(2 * streamChunk + 70001, (i) => (i * 7) % 253),
  );
  late Directory dir;
  late String originalPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('carrier_stream_');
    originalPath = '${dir.path}/original.heic';
    File(originalPath).writeAsBytesSync(original);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  CarrierHeader header({CarrierMeta? meta}) => newCarrierHeader(
    masterSalt: masterSalt,
    thumbLength: carrierThumbPlain(thumbnail, meta).length,
    originalLength: original.length,
    extension: 'heic',
    meta: meta,
  );

  test('CTR from an offset is the one-shot stream, across a wrap', () {
    // The low 64 bits about to wrap: CommonCrypto wraps them without a
    // carry into the high half, and the offset has to agree.
    final iv = Uint8List.fromList([
      ...List.filled(7, 0x11),
      0x22,
      ...List.filled(8, 0xFF),
    ]);
    final key = Uint8List.fromList(List.generate(32, (i) => 200 - i));
    final data = Uint8List.fromList(List.generate(160, (i) => i));
    final whole = cipher.transform(key: key, iv: iv, data: data);
    final pieces = [
      for (var at = 0; at < data.length; at += 32)
        ...ctrAt(
          cipher,
          key: key,
          iv: iv,
          offset: at,
          data: Uint8List.sublistView(data, at, at + 32),
        ),
    ];
    expect(pieces, whole);
  });

  for (final v2 in [false, true]) {
    final m = v2
        ? CarrierMeta(
            takenAt: DateTime.utc(2024, 3, 4),
            width: 4032,
            height: 3024,
            isVideo: false,
          )
        : null;

    test('a JPEG carrier written as a stream is byte for byte the built one'
        '${v2 ? ' (v2)' : ''}', () {
      final h = header(meta: m);
      final decoy = decoyJpeg();
      final built = buildJpegCarrier(
        cipher: cipher,
        keys: keys,
        masterSalt: masterSalt,
        decoy: decoy,
        thumbnail: thumbnail,
        original: original,
        extension: 'heic',
        meta: m,
        header: h,
      )!;
      final out = '${dir.path}/c.jpg';
      expect(
        writeCarrierFile(
          cipher: cipher,
          keys: keys,
          masterSalt: masterSalt,
          decoy: decoy,
          video: false,
          thumbnail: thumbnail,
          originalPath: originalPath,
          extension: 'heic',
          outPath: out,
          meta: m,
          header: h,
        ),
        isTrue,
      );
      expect(File(out).readAsBytesSync(), built);
    });
  }

  test('an MP4 carrier written as a stream is byte for byte the built one', () {
    final h = header();
    final decoy = decoyMp4();
    final built = buildMp4Carrier(
      cipher: cipher,
      keys: keys,
      masterSalt: masterSalt,
      decoy: decoy,
      poster: thumbnail,
      original: original,
      extension: 'heic',
      header: h,
    )!;
    final out = '${dir.path}/c.mov';
    expect(
      writeCarrierFile(
        cipher: cipher,
        keys: keys,
        masterSalt: masterSalt,
        decoy: decoy,
        video: true,
        thumbnail: thumbnail,
        originalPath: originalPath,
        extension: 'heic',
        outPath: out,
        header: h,
      ),
      isTrue,
    );
    expect(File(out).readAsBytesSync(), built);
  });

  test('a decoy of the wrong kind writes nothing', () {
    final out = '${dir.path}/c.jpg';
    expect(
      writeCarrierFile(
        cipher: cipher,
        keys: keys,
        masterSalt: masterSalt,
        decoy: decoyMp4(),
        video: false,
        thumbnail: thumbnail,
        originalPath: originalPath,
        extension: 'heic',
        outPath: out,
      ),
      isFalse,
    );
    expect(File(out).existsSync(), isFalse);
  });

  group('opening a carrier file', () {
    String carrier({required bool video}) {
      final path = '${dir.path}/c.${video ? 'mov' : 'jpg'}';
      final bytes = video
          ? buildMp4Carrier(
              cipher: cipher,
              keys: keys,
              masterSalt: masterSalt,
              decoy: decoyMp4(),
              poster: thumbnail,
              original: original,
              extension: 'mov',
            )!
          : buildJpegCarrier(
              cipher: cipher,
              keys: keys,
              masterSalt: masterSalt,
              decoy: decoyJpeg(),
              thumbnail: thumbnail,
              original: original,
              extension: 'heic',
            )!;
      File(path).writeAsBytesSync(bytes);
      return path;
    }

    for (final video in [false, true]) {
      test('reads what openCarrier reads (${video ? 'mp4' : 'jpeg'})', () {
        final path = carrier(video: video);
        final opened = openCarrierFile(cipher: cipher, keys: keys, path: path)!;
        final whole = openCarrier(
          cipher: cipher,
          keys: keys,
          payload: payloadOf(File(path).readAsBytesSync())!,
        )!;
        expect(opened.original, whole.original);
        expect(opened.original, original);
        expect(opened.extension, video ? 'mov' : 'heic');
      });
    }

    test('writes the original to the path named for its extension', () {
      final path = carrier(video: true);
      final opened = openCarrierFile(
        cipher: cipher,
        keys: keys,
        path: path,
        toPath: (ext) => '${dir.path}/plain.$ext',
      )!;
      expect(opened.original, isEmpty);
      expect(File('${dir.path}/plain.mov').readAsBytesSync(), original);
      expect(File('${dir.path}/plain.mov.part').existsSync(), isFalse);
    });

    test('another album\'s key, a changed byte or an ordinary file: null, '
        'and nothing written', () {
      final path = carrier(video: false);
      String to(String ext) => '${dir.path}/plain.$ext';
      expect(
        openCarrierFile(
          cipher: cipher,
          keys: otherKeys,
          path: path,
          toPath: to,
        ),
        isNull,
      );

      final bytes = File(path).readAsBytesSync();
      final payloadAt = _lastCarrierSegment(bytes);
      bytes[payloadAt] ^= 1;
      File(path).writeAsBytesSync(bytes);
      expect(
        openCarrierFile(cipher: cipher, keys: keys, path: path, toPath: to),
        isNull,
      );

      final plain = '${dir.path}/plain.jpg';
      File(plain).writeAsBytesSync(decoyJpeg());
      expect(openCarrierFile(cipher: cipher, keys: keys, path: plain), isNull);
      expect(File(to('heic')).existsSync(), isFalse);
    });
  });
}

/// A byte inside the last `APP7` segment: part of the encrypted original.
int _lastCarrierSegment(Uint8List bytes) {
  var i = 2;
  var last = -1;
  while (bytes[i + 1] != 0xDA) {
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (bytes[i + 1] == jpegCarrierMarker) last = i + 4;
    i += 2 + length;
  }
  return last + 10;
}

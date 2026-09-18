import 'dart:typed_data';

import 'package:photos_vault/photos/image_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('reencodeAsWebP re-encodes a decodable still image as WebP', () {
    final png = Uint8List.fromList(
      img.encodePng(img.Image(width: 4, height: 4)),
    );

    final webp = reencodeAsWebP(png);

    expect(webp, isNotNull);
    // WebP's RIFF container: bytes 0-3 "RIFF", bytes 8-11 "WEBP".
    expect(String.fromCharCodes(webp!.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(webp.sublist(8, 12)), 'WEBP');
  });

  test(
    'reencodeAsWebP returns null for bytes that are not a decodable image',
    () {
      final notAnImage = Uint8List.fromList(
        'this is a video file, not a photo'.codeUnits,
      );

      expect(reencodeAsWebP(notAnImage), isNull);
    },
  );

  group('encodeThumbnail', () {
    test(
      'scales an oversized image down to the max edge, preserving aspect',
      () {
        final big = Uint8List.fromList(
          img.encodeJpg(img.Image(width: 2048, height: 1024)),
        );

        final thumbnail = encodeThumbnail(big);

        final decoded = img.decodeImage(thumbnail!)!;
        expect(decoded.width, thumbnailMaxEdge);
        expect(decoded.height, thumbnailMaxEdge ~/ 2);
      },
    );

    test('scales by the taller edge for a portrait image', () {
      final tall = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 600, height: 1200)),
      );

      final decoded = img.decodeImage(encodeThumbnail(tall)!)!;

      expect(decoded.height, thumbnailMaxEdge);
      expect(decoded.width, thumbnailMaxEdge ~/ 2);
    });

    test(
      'leaves an already-small image byte-identical rather than re-compressing',
      () {
        final small = Uint8List.fromList(
          img.encodeJpg(img.Image(width: 64, height: 64)),
        );

        expect(encodeThumbnail(small), same(small));
      },
    );

    test('returns null for bytes that are not a decodable image', () {
      expect(
        encodeThumbnail(Uint8List.fromList('a video, not a photo'.codeUnits)),
        isNull,
      );
    });
  });
}

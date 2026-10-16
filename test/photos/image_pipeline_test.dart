import 'dart:typed_data';

import 'package:photos_vault/photos/image_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
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

  test('a byte budget shrinks a small photo that is already its own size', () {
    // 300px on a side, so untouched without a budget — but noisy, so at
    // quality 100 it is far bigger than a carrier's prefix can hold.
    final noisy = img.Image(width: 300, height: 300);
    var seed = 7;
    for (final px in noisy) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      px.setRgb(seed & 255, (seed >> 8) & 255, (seed >> 16) & 255);
    }
    final bytes = Uint8List.fromList(img.encodeJpg(noisy, quality: 100));
    expect(encodeThumbnail(bytes), same(bytes));

    final budget = bytes.length ~/ 2;
    final fitted = encodeThumbnail(bytes, maxBytes: budget)!;
    expect(fitted.length, lessThanOrEqualTo(budget));
    expect(img.decodeImage(fitted), isNotNull);
  });

  group('WP13b: header size and the optimized format', () {
    test('pixelsOf reads every format decodePhoto takes', () {
      final image = img.Image(width: 30, height: 20);
      expect(pixelsOf(Uint8List.fromList(img.encodeJpg(image))), 600);
      expect(pixelsOf(Uint8List.fromList(img.encodePng(image))), 600);
      expect(pixelsOf(Uint8List.fromList(img.encodeGif(image))), 600);
      expect(pixelsOf(Uint8List.fromList(img.encodeBmp(image))), 600);
      expect(pixelsOf(Uint8List.fromList(img.encodeWebP(image))), 600);
      expect(pixelsOf(Uint8List(16)), isNull);
    });

    test('an image too big to decode safely is refused from its header '
        '(05#18)', () {
      final png = Uint8List.fromList(
        img.encodePng(img.Image(width: 4, height: 4)),
      );
      // The IHDR says 20000 × 20000; nothing is decoded to find out.
      ByteData.sublistView(png)
        ..setUint32(16, 20000)
        ..setUint32(20, 20000);
      expect(decodePhoto(png), isNull);
    });

    test('an opaque photo optimizes to JPEG, one with alpha to WebP '
        '(05#19)', () {
      final opaque = Uint8List.fromList(
        img.encodePng(img.Image(width: 400, height: 200)),
      );
      final clear = Uint8List.fromList(
        img.encodePng(img.Image(width: 400, height: 200, numChannels: 4)),
      );

      final (jpeg, w, h) = optimizeStill(opaque, maxEdge: 100)!;
      final (webp, _, _) = optimizeStill(clear)!;

      expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
      expect((w, h), (100, 50));
      expect(String.fromCharCodes(webp.sublist(8, 12)), 'WEBP');
    });
  });
}

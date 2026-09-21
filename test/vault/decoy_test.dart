import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photos_vault/vault/decoy.dart';
import 'package:photos_vault/vault/jpeg_segments.dart';

DecoySource _source(String id, int size, {bool isVideo = false}) => DecoySource(
  id: id,
  sizeBytes: size,
  width: 4032,
  height: 3024,
  takenAt: DateTime(2026, 3, 4, 5, 6, 7),
  isVideo: isVideo,
);

Uint8List _thumbnail() {
  final image = img.Image(width: 320, height: 240);
  for (var y = 0; y < 240; y++) {
    for (var x = 0; x < 320; x++) {
      image.setPixelRgb(x, y, (x * 3) % 255, (y * 5) % 255, 90);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 70));
}

void main() {
  test('picks a decoy near the payload size, never a video for a photo', () {
    final candidates = [
      _source('tiny', 50 * 1024),
      _source('close', 2 * 1024 * 1024),
      _source('closer', 2100 * 1024),
      _source('huge', 80 * 1024 * 1024),
      _source('movie', 2 * 1024 * 1024, isVideo: true),
    ];
    final chosen = chooseDecoy(
      candidates: candidates,
      payloadBytes: 2 * 1024 * 1024,
      wantVideo: false,
      spread: 2,
      random: Random(1),
    );
    expect(chosen, isNotNull);
    expect(['close', 'closer'], contains(chosen!.id));
    expect(chosen.isVideo, isFalse);
  });

  test('skips a decoy already used twice', () {
    final chosen = chooseDecoy(
      candidates: [_source('a', 1000), _source('b', 1001)],
      payloadBytes: 1000,
      wantVideo: false,
      usedCounts: const {'a': 2},
      spread: 1,
      random: Random(2),
    );
    expect(chosen!.id, 'b');
  });

  test('refuses rather than inventing one when nothing fits', () {
    expect(
      chooseDecoy(
        candidates: [_source('movie', 10, isVideo: true)],
        payloadBytes: 10,
        wantVideo: false,
      ),
      isNull,
    );
  });

  test('a built decoy is a real JPEG at the asked-for size', () {
    final decoy = buildDecoyJpeg(
      thumbnail: _thumbnail(),
      width: 4032,
      height: 3024,
      takenAt: DateTime(2026, 3, 4, 5, 6, 7),
    );
    expect(decoy, isNotNull);
    final decoded = img.decodeJpg(decoy!);
    expect(decoded!.width, 4032);
    expect(decoded.height, 3024);
  });

  test('an upscaled thumbnail stays small at 12 MP', () {
    final decoy = buildDecoyJpeg(
      thumbnail: _thumbnail(),
      width: 4032,
      height: 3024,
      takenAt: DateTime(2026, 3, 4),
    )!;
    // The whole bloat argument rests on this staying well under a megabyte.
    expect(decoy.length, lessThan(1024 * 1024));
  });

  test('carries the decoy date, and only the decoy date', () {
    final decoy = buildDecoyJpeg(
      thumbnail: _thumbnail(),
      width: 640,
      height: 480,
      takenAt: DateTime(2026, 3, 4, 5, 6, 7),
    )!;
    final app1 = parseJpeg(decoy)!.segments.firstWhere((s) => s.marker == 0xE1);
    expect(String.fromCharCodes(app1.data.sublist(0, 4)), 'Exif');
    expect(
      String.fromCharCodes(app1.data).contains('2026:03:04 05:06:07'),
      isTrue,
    );
  });
}

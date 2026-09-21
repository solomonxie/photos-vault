import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/carrier_upload.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/decoy.dart';
import 'package:photos_vault/vault/jpeg_segments.dart';
import 'package:photos_vault/vault/keys.dart';

AlbumKeys _keys() => AlbumKeys(
  albumKey: Uint8List.fromList(List.generate(32, (i) => i * 5 % 256)),
  entry: PassphraseEntry(
    id: 'e1',
    salt: Uint8List.fromList(List.generate(16, (i) => i)),
    verifier: Uint8List(32),
    hint: '',
  ),
);

Uint8List _jpeg(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, x % 200, y % 200, 120);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 70));
}

AssetRecord _hidden({bool isVideo = false}) => AssetRecord(
  localId: 'hidden-1',
  contentHash: 'h',
  platform: 'ios',
  createdAt: DateTime(2026, 1, 2),
  updatedAt: DateTime(2026, 1, 2),
  passcodeHash: 'somehash',
  isVideo: isVideo,
  width: 4032,
  height: 3024,
);

DecoyCandidate _candidate(String id, int size) => DecoyCandidate(
  source: DecoySource(
    id: id,
    sizeBytes: size,
    width: 1280,
    height: 960,
    takenAt: DateTime(2025, 6, 7, 8, 9, 10),
    isVideo: false,
  ),
  thumbnail: () async => _jpeg(320, 240),
);

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('carrier_upload_test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('builds a carrier that opens back into the original photo', () async {
    final original = _jpeg(800, 600);
    final source = File('${temp.path}/original.jpg')
      ..writeAsBytesSync(original);

    final builder = CarrierBuilder(temporaryDirectory: () async => temp);
    final keys = _keys();
    final carrier = await builder.build(
      record: _hidden(),
      filePath: source.path,
      keys: keys,
      candidates: [
        _candidate('near', original.length),
        _candidate('far', original.length * 40),
      ],
    );

    expect(carrier, isNotNull);
    final bytes = await carrier!.readAsBytes();

    // It is a photo of the decoy's size, not the hidden one's.
    final decoded = img.decodeJpg(bytes)!;
    expect(decoded.width, 1280);
    expect(decoded.height, 960);

    final opened = openCarrier(
      cipher: PlatformCipher(),
      keys: keys.carrier,
      payload: payloadOf(bytes)!,
    );
    expect(opened!.original, equals(original));
    expect(opened.extension, 'jpg');
  });

  test('a grid tile comes out of the first 64 KB', () async {
    final original = _jpeg(800, 600);
    final source = File('${temp.path}/original.jpg')
      ..writeAsBytesSync(original);
    final keys = _keys();
    final carrier = await CarrierBuilder(temporaryDirectory: () async => temp)
        .build(
          record: _hidden(),
          filePath: source.path,
          keys: keys,
          candidates: [_candidate('near', original.length)],
        );

    final bytes = await carrier!.readAsBytes();
    final prefix = Uint8List.sublistView(
      bytes,
      0,
      bytes.length < thumbnailPrefixBytes ? bytes.length : thumbnailPrefixBytes,
    );
    final thumb = openThumbnail(
      cipher: PlatformCipher(),
      keys: keys.carrier,
      payloadPrefix: carrierPayloadFromPrefix(prefix),
    );
    expect(thumb, isNotNull);
    expect(img.decodeJpg(thumb!), isNotNull);
  });

  test('refuses rather than uploading when there is no decoy', () async {
    final source = File('${temp.path}/original.jpg')
      ..writeAsBytesSync(_jpeg(800, 600));
    final carrier = await CarrierBuilder(temporaryDirectory: () async => temp)
        .build(
          record: _hidden(),
          filePath: source.path,
          keys: _keys(),
          candidates: const [],
        );
    expect(carrier, isNull);
  });

  test('a video with no decoy video is refused, not sent as a still', () async {
    final source = File('${temp.path}/clip.mov')
      ..writeAsBytesSync(Uint8List.fromList(List.filled(4096, 9)));
    final carrier =
        await CarrierBuilder(
          temporaryDirectory: () async => temp,
          posterFrame: (_) async => _jpeg(320, 240),
        ).build(
          record: _hidden(isVideo: true),
          filePath: source.path,
          keys: _keys(),
          candidates: [_candidate('photo-only', 4096)],
        );
    expect(carrier, isNull);
  });
}

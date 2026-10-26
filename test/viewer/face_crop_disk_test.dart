import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/viewer/face_crop_disk.dart';

void main() {
  test('file names are stable and tell keys apart', () {
    expect(
      FaceCropDisk.fileNameFor('a|f|276|1'),
      FaceCropDisk.fileNameFor('a|f|276|1'),
    );
    expect(
      FaceCropDisk.fileNameFor('a|f|276|1'),
      isNot(FaceCropDisk.fileNameFor('a|f|276|2')),
    );
  });

  testWidgets('a crop written is read back; a missing one is null', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('crops');
      addTearDown(() => dir.delete(recursive: true));
      final disk = FaceCropDisk(root: () async => dir);
      final pixels = Uint8List(8 * 8 * 4)..fillRange(0, 8 * 8 * 4, 200);
      final codec = await ui.ImageDescriptor.raw(
        await ui.ImmutableBuffer.fromUint8List(pixels),
        width: 8,
        height: 8,
        pixelFormat: ui.PixelFormat.rgba8888,
      ).instantiateCodec();
      final image = (await codec.getNextFrame()).image;
      await disk.write('k', image);
      final back = await disk.read('k');
      expect(back?.width, 8);
      expect(await disk.read('other'), isNull);
    });
  });
}

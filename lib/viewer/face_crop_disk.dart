import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Avatar face crops kept between launches, as small JPEGs in Caches.
///
/// A crop costs a 512–1536 px photo decode; reading one back is a ~20 KB
/// file. Without this every launch decoded every avatar on screen again —
/// seconds for a row of People. A cache only: the OS may purge it, and
/// anything missing is simply cropped again.
class FaceCropDisk {
  FaceCropDisk({Future<Directory> Function()? root})
    : _root = root ?? _defaultRoot;

  final Future<Directory> Function() _root;
  Future<Directory>? _dir;

  static Future<Directory> _defaultRoot() async =>
      Directory('${(await getApplicationCacheDirectory()).path}/face_crops');

  Future<Directory> get _folder => _dir ??= () async {
    final dir = await _root();
    await dir.create(recursive: true);
    return dir;
  }();

  Future<File> _file(String key) async =>
      File('${(await _folder).path}/${fileNameFor(key)}.jpg');

  /// The crop saved under [key], decoded; null if there is none.
  Future<ui.Image?> read(String key) async {
    try {
      final bytes = await (await _file(key)).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  /// Saved in the background; a failure only means cropping again later.
  Future<void> write(String key, ui.Image image) async {
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return;
      final width = image.width, height = image.height;
      final rgba = data.buffer.asUint8List();
      final jpeg = await Isolate.run(() => encodeCrop(rgba, width, height));
      await (await _file(key)).writeAsBytes(jpeg, flush: false);
    } catch (_) {
      // Cropped again next launch.
    }
  }

  /// FNV-1a 64: stable across runs, unlike `String.hashCode`.
  static String fileNameFor(String key) {
    var hash = 0xcbf29ce484222325;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toUnsigned(64).toRadixString(16);
  }
}

Uint8List encodeCrop(Uint8List rgba, int width, int height) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    numChannels: 4,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: 85));
}

final faceCropDisk = FaceCropDisk();

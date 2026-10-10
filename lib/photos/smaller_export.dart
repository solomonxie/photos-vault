import 'package:flutter/services.dart';

/// How small a resize makes a photo: the longest edge, in pixels, or null
/// to keep it — still re-encoded as HEIF, which is where most of the
/// saving is.
enum ExportSize {
  original(null),
  large(2048),
  medium(1280),
  small(640);

  const ExportSize(this.maxEdge);

  final int? maxEdge;
}

const _quality = 82;

const _encodeChannel = MethodChannel('byo.photos/image_encode');

/// [bytes] re-encoded by ImageIO (`ImageEncodeChannel.swift`) as `heic` or
/// `jpeg`, shrunk to [maxEdge] when given; EXIF and GPS kept. Null when the
/// platform refuses or has no such channel (tests).
Future<Uint8List?> encodeNatively(
  Uint8List bytes, {
  required String format,
  int? maxEdge,
}) async {
  try {
    return await _encodeChannel.invokeMethod<Uint8List>('encode', {
      'bytes': bytes,
      'format': format,
      'maxEdge': ?maxEdge,
      'quality': _quality / 100,
    });
  } catch (_) {
    // No channel (tests), or the platform refused.
    return null;
  }
}

/// [input] re-encoded by ImageIO into [output], file to file — a full-size
/// photo never crosses the channel. True only when [output] was written,
/// which by default means it came out smaller.
Future<bool> encodeFileNatively({
  required String input,
  required String output,
  required String format,
  int? maxEdge,
  bool onlyIfSmaller = true,
}) async {
  try {
    return await _encodeChannel.invokeMethod<bool>('encodeFile', {
          'input': input,
          'output': output,
          'format': format,
          'maxEdge': ?maxEdge,
          'onlyIfSmaller': onlyIfSmaller,
          'quality': _quality / 100,
        }) ??
        false;
  } catch (_) {
    // No channel (tests), or the platform refused.
    return false;
  }
}

/// [bytes] as HEIF no longer than [size] on its longest edge, from iOS's
/// own encoder. Null when they aren't a still the platform can decode — no
/// other format: a resize is HEIF or nothing.
Future<({Uint8List bytes, String extension})?> shrinkPhoto(
  Uint8List bytes,
  ExportSize size,
) async {
  final heic = await encodeNatively(
    bytes,
    format: 'heic',
    maxEdge: size.maxEdge,
  );
  return heic == null ? null : (bytes: heic, extension: '.heic');
}

/// [input] as 1080p HEVC at [output] (`ImageEncodeChannel.swift`). True
/// only when it was written and came out smaller; otherwise
/// [lastVideoCompressError] says why.
Future<bool> compressVideoNatively({
  required String input,
  required String output,
}) async {
  try {
    final answer = await _encodeChannel.invokeMethod<Object>('compressVideo', {
      'input': input,
      'output': output,
    });
    if (answer == true) return true;
    lastVideoCompressError = '$answer';
  } catch (e) {
    lastVideoCompressError = '$e';
  }
  return false;
}

String? lastVideoCompressError;

import 'dart:io';

import 'package:flutter/services.dart';

/// The decoy half of a video carrier, rendered by AVFoundation: one still
/// held for a real duration.
///
/// Duration is what makes the object plausible. The same 200 MB over two
/// seconds is 800 Mbps and over three minutes is 9 Mbps, and only one of
/// those is a video anyone ever shot. So the caller hands over the shape of
/// a real video of about the payload's size and this fills it.
///
/// No encoder ships with the app: AVFoundation is already on the phone and
/// does this in hardware. A packaged one (ffmpeg and friends) is tens of
/// megabytes against 0.8 MB of headroom.
class StillVideo {
  const StillVideo({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('byo.photos/still_video');

  final MethodChannel _channel;

  /// Writes a video to [path] showing [still] for [duration]. Null when the
  /// platform declines, which the caller treats as "no decoy available" and
  /// therefore "do not upload".
  Future<File?> render({
    required Uint8List still,
    required int width,
    required int height,
    required Duration duration,
    required String path,
    int fps = 30,
  }) async {
    if (duration <= Duration.zero || width <= 0 || height <= 0) return null;
    try {
      final written = await _channel.invokeMethod<String>('render', {
        'still': still,
        'width': width,
        'height': height,
        'seconds': duration.inMilliseconds / 1000,
        'fps': fps,
        'path': path,
      });
      return written == null ? null : File(written);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // Tests, and any platform without the channel.
      return null;
    }
  }
}

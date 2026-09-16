import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Stands in for the real `video_player` plugin so viewer tests can drive a
/// [VideoPlayerController] without a platform channel. Records the calls the
/// playback controls make, and reports the clip as initialised right away.
class FakeVideoPlayerPlatform extends VideoPlayerPlatform
    with MockPlatformInterfaceMixin {
  FakeVideoPlayerPlatform({
    this.duration = const Duration(seconds: 30),
    this.size = const Size(1920, 1080),
  });

  final Duration duration;
  final Size size;

  final seeks = <Duration>[];
  final calls = <String>[];
  double volume = 1;

  Duration position = Duration.zero;

  /// Not broadcast: the controller only subscribes after
  /// [createWithOptions] returns, and a buffering stream is what keeps the
  /// "initialized" event from being dropped in between.
  final _events = StreamController<VideoEvent>();

  static FakeVideoPlayerPlatform install({
    Duration duration = const Duration(seconds: 30),
  }) {
    final fake = FakeVideoPlayerPlatform(duration: duration);
    VideoPlayerPlatform.instance = fake;
    return fake;
  }

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) async => 1;

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    _events.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: duration,
        size: size,
      ),
    );
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events.stream;

  @override
  Future<void> dispose(int playerId) async {
    await _events.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> play(int playerId) async => calls.add('play');

  @override
  Future<void> pause(int playerId) async => calls.add('pause');

  @override
  Future<void> setVolume(int playerId, double value) async {
    volume = value;
    calls.add('volume:$value');
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration to) async {
    position = to;
    seeks.add(to);
    calls.add('seek');
  }

  @override
  Future<Duration> getPosition(int playerId) async => position;

  @override
  Widget buildView(int playerId) => const SizedBox.shrink();
}

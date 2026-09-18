import 'dart:io';

import 'package:photos_vault/viewer/video_controls.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';

import '../support/fake_video_player_platform.dart';

void main() {
  late FakeVideoPlayerPlatform platform;
  late VideoPlayerController controller;

  setUp(() async {
    platform = FakeVideoPlayerPlatform.install(
      duration: const Duration(minutes: 2, seconds: 30),
    );
    controller = VideoPlayerController.file(File('/tmp/clip.mp4'));
    await controller.initialize();
  });

  tearDown(() => controller.dispose());

  Future<void> pumpControls(WidgetTester tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            child: VideoControls(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows elapsed and remaining time', (tester) async {
    await pumpControls(tester);

    expect(find.text('0:00'), findsOneWidget);
    expect(find.text('-2:30'), findsOneWidget);
  });

  testWidgets('play/pause button drives the player', (tester) async {
    await pumpControls(tester);

    await tester.tap(find.byIcon(CupertinoIcons.play_fill));
    await tester.pump();
    expect(platform.calls, contains('play'));
    expect(find.byIcon(CupertinoIcons.pause_fill), findsOneWidget);

    await tester.tap(find.byIcon(CupertinoIcons.pause_fill));
    await tester.pump();
    expect(platform.calls, contains('pause'));
  });

  testWidgets('tapping the timeline seeks to that point', (tester) async {
    await pumpControls(tester);

    final timeline = find.byType(LayoutBuilder).first;
    final box = tester.getRect(timeline);
    await tester.tapAt(Offset(box.left + box.width / 2, box.center.dy));
    await tester.pump();

    expect(platform.seeks, isNotEmpty);
    expect(
      platform.seeks.last.inSeconds,
      closeTo(75, 6),
      reason: 'halfway along a 2:30 clip',
    );
  });

  testWidgets('scrubbing pauses, seeks live, and resumes after', (
    tester,
  ) async {
    await pumpControls(tester);
    await controller.play();
    await tester.pump();
    platform.calls.clear();

    final box = tester.getRect(find.byType(LayoutBuilder).first);
    final gesture = await tester.startGesture(
      Offset(box.left + 10, box.center.dy),
    );
    await tester.pump();
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();

    expect(platform.calls, contains('pause'));
    expect(platform.seeks, isNotEmpty, reason: 'seeks while still dragging');

    await gesture.up();
    await tester.pump();
    expect(platform.calls.last, 'play');

    // Playing leaves `video_player`'s position poll running.
    await controller.pause();
    await tester.pump();
  });

  testWidgets('mute toggles the volume', (tester) async {
    await pumpControls(tester);

    await tester.tap(find.byIcon(CupertinoIcons.speaker_2_fill));
    await tester.pump();
    expect(platform.volume, 0);
    expect(find.byIcon(CupertinoIcons.speaker_slash_fill), findsOneWidget);

    await tester.tap(find.byIcon(CupertinoIcons.speaker_slash_fill));
    await tester.pump();
    expect(platform.volume, 1);
  });
}

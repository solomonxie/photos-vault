import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:photos_vault/viewer/gif_view.dart';
import 'package:photos_vault/viewer/motion_playback.dart';

void main() {
  late Directory tempDir;
  late File gif;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pv_gif_');
    final animation = img.Image(width: 4, height: 4, numChannels: 4)
      ..frameDuration = 40;
    animation.addFrame(img.Image(width: 4, height: 4, numChannels: 4));
    gif = File('${tempDir.path}/a.gif')
      ..writeAsBytesSync(img.encodeGif(animation));
  });
  tearDown(() => tempDir.delete(recursive: true));

  Widget wrap(MotionPlayMode mode, {ValueChanged<bool>? onPlayingChanged}) =>
      CupertinoApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: GifView(
              file: gif,
              mode: mode,
              onPlayingChanged: onPlayingChanged,
              errorBuilder: (context, error, stack) => const SizedBox.shrink(),
            ),
          ),
        ),
      );

  /// The first frame is decoded off a real file, which a `testWidgets`
  /// fake-async zone never lets finish on its own.
  Future<void> show(WidgetTester tester, Widget app) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(app);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
  }

  /// `Image` is the widget that animates a GIF; the frozen state is a
  /// `RawImage` of one decoded frame, with no `Image` above it.
  void expectPlaying(bool playing) {
    expect(find.byType(Image), playing ? findsOneWidget : findsNothing);
    expect(find.byType(RawImage), findsOneWidget);
  }

  testWidgets('loop runs it, and says so', (tester) async {
    final playing = <bool>[];

    await show(
      tester,
      wrap(MotionPlayMode.loop, onPlayingChanged: playing.add),
    );

    expectPlaying(true);
    expect(playing.last, isTrue);
  });

  testWidgets('still freezes it on its first frame', (tester) async {
    await show(tester, wrap(MotionPlayMode.still));

    expectPlaying(false);
  });

  testWidgets('hold plays only while held', (tester) async {
    final playing = <bool>[];
    await show(
      tester,
      wrap(MotionPlayMode.hold, onPlayingChanged: playing.add),
    );
    expectPlaying(false);

    final press = await tester.startGesture(
      tester.getCenter(find.byType(GifView)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expectPlaying(true);
    expect(playing.last, isTrue);

    await press.up();
    await tester.pumpAndSettle();
    expectPlaying(false);
    expect(playing.last, isFalse);
  });

  testWidgets('switching mode stops a running one', (tester) async {
    await show(tester, wrap(MotionPlayMode.loop));
    expectPlaying(true);

    await tester.pumpWidget(wrap(MotionPlayMode.still));
    await tester.pumpAndSettle();

    expectPlaying(false);
  });
}

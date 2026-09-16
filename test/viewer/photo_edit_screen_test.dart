import 'dart:io';
import 'dart:typed_data';

import 'package:bring_your_own_photos/l10n/app_localizations.dart';
import 'package:bring_your_own_photos/viewer/photo_edit_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

// Never reads from disk — real file I/O never completes under `testWidgets`'
// fake async.
Future<Uint8List> Function(File) _photoBytes() {
  final image = img.Image(width: 40, height: 20);
  img.fill(image, color: img.ColorRgb8(20, 120, 220));
  final bytes = Uint8List.fromList(img.encodePng(image));
  return (_) async => bytes;
}

void main() {
  testWidgets('the rotate dial starts at 0° and follows a spin', (
    tester,
  ) async {
    // Decoding the image for its dimensions is real async work — it only
    // runs under `runAsync`, not fake async.
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _wrap(
          PhotoEditScreen(
            file: File('/tmp/unused.png'),
            mode: PhotoEditMode.rotate,
            readBytes: _photoBytes(),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(find.text('Rotate'), findsOneWidget);
    expect(find.text('0°'), findsOneWidget);

    // Anywhere off-centre on the dial sets the angle to that direction.
    final dial = tester.getCenter(find.byType(CustomPaint).last);
    await tester.dragFrom(dial, const Offset(-40, 0));
    await tester.pumpAndSettle();

    expect(find.text('0°'), findsNothing);
  });

  testWidgets('Cancel leaves the photo alone', (tester) async {
    Object? popped = 'untouched';

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async {
              popped = await Navigator.of(context).push<Uint8List>(
                CupertinoPageRoute(
                  builder: (_) => PhotoEditScreen(
                    file: File('/tmp/unused.png'),
                    mode: PhotoEditMode.crop,
                    readBytes: _photoBytes(),
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Crop'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(popped, isNull);
  });
}

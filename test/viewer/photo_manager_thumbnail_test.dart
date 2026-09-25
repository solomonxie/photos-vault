import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/viewer/asset_grid.dart';

/// Two 1x1 PNGs, so the widget has something real to decode and the test
/// asserts on which photo is drawn rather than on a placeholder.
final _red = Uint8List.fromList(const [
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  2,
  0,
  0,
  0,
  144,
  119,
  83,
  222,
  0,
  0,
  0,
  12,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  248,
  207,
  192,
  0,
  0,
  3,
  1,
  1,
  0,
  201,
  254,
  146,
  239,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
]);
final _blue = Uint8List.fromList(const [
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  2,
  0,
  0,
  0,
  144,
  119,
  83,
  222,
  0,
  0,
  0,
  12,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  96,
  96,
  248,
  15,
  0,
  1,
  3,
  1,
  0,
  8,
  137,
  194,
  236,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
]);

Uint8List _drawn(WidgetTester tester) =>
    (tester.widget<Image>(find.byType(Image)).image as MemoryImage).bytes;

void main() {
  setUp(clearThumbnailCaches);

  testWidgets('the same tile handed a different photo draws the new one', (
    tester,
  ) async {
    rememberThumbnailBytes('a', _red);
    rememberThumbnailBytes('b', _blue);

    await tester.pumpWidget(
      const CupertinoApp(home: PhotoManagerThumbnail(assetId: 'a')),
    );
    expect(_drawn(tester), _red);

    // Same widget type in the same place, so Flutter keeps the element and
    // never calls initState again. This is an album cover whose newest
    // photo was just deleted: the record behind it changes, and the
    // picture has to change with it.
    await tester.pumpWidget(
      const CupertinoApp(home: PhotoManagerThumbnail(assetId: 'b')),
    );

    expect(_drawn(tester), _blue);
  });

  testWidgets('the same photo again is not reloaded out from under itself', (
    tester,
  ) async {
    rememberThumbnailBytes('a', _red);

    await tester.pumpWidget(
      const CupertinoApp(home: PhotoManagerThumbnail(assetId: 'a')),
    );
    await tester.pumpWidget(
      const CupertinoApp(
        home: PhotoManagerThumbnail(assetId: 'a', fit: BoxFit.contain),
      ),
    );

    expect(_drawn(tester), _red);
  });
}

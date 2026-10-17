import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/viewer/person_avatar.dart';

import '../support/fake_asset_record_store.dart';

/// Counts the reads an avatar makes of its own.
class _CountingStore extends FakeAssetRecordStore {
  var reads = 0;

  @override
  Future<Map<String, AssetRecord>> getByLocalIds(Iterable<String> localIds) {
    reads++;
    return super.getByLocalIds(localIds);
  }
}

void main() {
  const photo = Size(4000, 3000);

  test('the crop is centred on the face, with room around it', () {
    // A face a fifth of the way across a group shot — not centre-frame.
    const face = FaceRect(0.18, 0.30, 0.08, 0.10);

    final rect = faceCropRect(photo, face);

    expect(rect.center.dx, closeTo((0.18 + 0.04) * photo.width, 0.01));
    expect(rect.center.dy, closeTo((0.30 + 0.05) * photo.height, 0.01));
    expect(rect.width, rect.height);
    expect(rect.width, greaterThan(face.height * photo.height));
  });

  test('a face at the frame edge slides inside, it does not squash', () {
    const face = FaceRect(0.94, 0.02, 0.05, 0.07);

    final rect = faceCropRect(photo, face);

    expect(rect.width, closeTo(rect.height, 0.001));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(photo.width + 0.001));
    expect(rect.bottom, lessThanOrEqualTo(photo.height));
  });

  test('a face bigger than the photo is capped at its shorter side', () {
    const face = FaceRect(0, 0, 1, 1);

    final rect = faceCropRect(photo, face);

    expect(rect.width, photo.height);
    expect(rect.height, photo.height);
  });

  test('a small face is decoded from more of the photo, a large one less', () {
    // A flat decode cap was the bug: 1024px of a whole frame is a hundred
    // pixels of a face filling a tenth of it, blown up into a circle
    // three hundred device-pixels across.
    int widthFor(double faceWidth) =>
        decodeWidthForFace(FaceRect(0.1, 0.1, faceWidth, faceWidth), 96, 3);

    expect(widthFor(0.1), greaterThan(widthFor(0.5)));
    // Bounded at both ends — a full 12-megapixel decode per avatar is
    // memory spent on detail nobody can see.
    expect(widthFor(0.001), lessThanOrEqualTo(maxFaceDecode));
    expect(widthFor(1.0), greaterThanOrEqualTo(512));
  });

  testWidgets('given the records, a row of avatars reads nothing', (
    tester,
  ) async {
    final store = _CountingStore();
    final record = AssetRecord(
      localId: 'a',
      contentHash: 'a',
      platform: 'test',
      sourceType: AssetSourceType.manualFile,
      sourcePath: '/nowhere/a.jpg',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

    await tester.pumpWidget(
      CupertinoApp(
        home: Column(
          children: [
            for (var i = 0; i < 3; i++)
              PersonAvatar(
                assetRecordStore: store,
                localId: 'a',
                records: {'a': record},
              ),
            // Not in the map: hidden, binned or gone. The glyph, no query.
            PersonAvatar(
              assetRecordStore: store,
              localId: 'missing',
              records: {'a': record},
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(store.reads, 0);
    expect(find.byType(Image), findsNWidgets(3));
    expect(find.byIcon(CupertinoIcons.person_fill), findsOneWidget);
  });

  testWidgets('without them, it asks the store', (tester) async {
    final store = _CountingStore();

    await tester.pumpWidget(
      CupertinoApp(
        home: PersonAvatar(assetRecordStore: store, localId: 'a'),
      ),
    );
    await tester.pump();

    expect(store.reads, 1);
  });

  test('the crop cache keeps the newest and frees the rest', () async {
    final cache = FaceCropCache(2);
    final images = [for (var i = 0; i < 3; i++) await createTestImage()];

    cache.put('a', images[0]);
    cache.put('b', images[1]);
    cache.take('a')?.dispose();
    cache.put('c', images[2]);

    expect(cache.length, 2);
    expect(images[1].debugDisposed, isTrue);
    final held = cache.take('a');
    expect(held, isNotNull);
    held!.dispose();
    expect(images[0].debugDisposed, isFalse);
    cache.clear();
    expect(images[0].debugDisposed, isTrue);
  });

  test(
    'a face crop is the square around the face, at the size asked',
    () async {
      final photo = await createTestImage(width: 400, height: 300);

      final crop = await cropFace(
        photo,
        const FaceRect(0.4, 0.4, 0.1, 0.1),
        64,
      );

      expect((crop.width, crop.height), (64, 64));
      crop.dispose();
      photo.dispose();
    },
  );
}

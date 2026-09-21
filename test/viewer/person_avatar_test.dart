import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/viewer/person_avatar.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

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
    expect(widthFor(0.001), lessThanOrEqualTo(3072));
    expect(widthFor(1.0), greaterThanOrEqualTo(512));
  });
}

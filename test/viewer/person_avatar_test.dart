import 'package:bring_your_own_photos/photos/person.dart';
import 'package:bring_your_own_photos/viewer/person_avatar.dart';
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
}

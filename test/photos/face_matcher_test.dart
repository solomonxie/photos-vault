import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/face_matcher.dart';
import 'package:photos_vault/photos/on_device_vision.dart';

FaceDescriptor _of(List<double> v, {int revision = 1}) =>
    FaceDescriptor(vector: Float32List.fromList(v), revision: revision);

ConfirmedFace _face(String personId, List<double> v, {int revision = 1}) =>
    ConfirmedFace(
      personId: personId,
      localId: 'photo:$personId',
      descriptor: _of(v, revision: revision),
    );

void main() {
  const matcher = FaceMatcher(ceiling: 0.3, margin: 0.1);

  test('picks the nearest confirmed person', () {
    final match = matcher.match(_of([1, 0, 0]), [
      _face('nina', [1, 0.1, 0]),
      _face('sam', [0, 1, 0]),
    ]);
    expect(match?.personId, 'nina');
    expect(match!.distance, lessThan(0.1));
  });

  test('says nothing when nobody is close enough', () {
    // Otherwise every stranger gets named after whoever they are least
    // unlike, which is a wrong answer wearing a right one's clothes.
    expect(
      matcher.match(_of([0, 0, 0]), [
        _face('nina', [0, 0, 50]),
      ]),
      isNull,
    );
  });

  test('says nothing when two people are nearly as close', () {
    // Siblings. Picking one is a coin flip presented as an answer.
    expect(
      matcher.match(_of([1, 0, 0]), [
        _face('nina', [1, 0.20, 0]),
        _face('mei', [1, 0.23, 0]),
      ]),
      isNull,
    );
  });

  test('the margin is between people, not between one person’s own faces', () {
    // Five photos of Nina shouldn't block each other.
    final match = matcher.match(_of([1, 0, 0]), [
      _face('nina', [1, 0.05, 0]),
      _face('nina', [1, 0.15, 0]),
      _face('nina', [1, 0.25, 0]),
      _face('sam', [0, 1, 0]),
    ]);
    expect(match?.personId, 'nina');
  });

  test('ignores descriptors from another Vision revision', () {
    expect(
      matcher.match(_of([0, 0, 1]), [
        _face('nina', [0, 0, 1], revision: 2),
      ]),
      isNull,
    );
  });

  test('no opinion with nothing confirmed, or nothing to go on', () {
    expect(matcher.match(_of([0, 0, 1]), const []), isNull);
    expect(
      matcher.match(_of(const []), [
        _face('nina', [0, 0, 1]),
      ]),
      isNull,
    );
  });
}

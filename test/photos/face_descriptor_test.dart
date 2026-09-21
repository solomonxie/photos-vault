import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/face_crops.dart';
import 'package:photos_vault/photos/on_device_vision.dart';
import 'package:photos_vault/photos/person.dart';

FaceDescriptor _of(List<double> values, {int revision = 1}) =>
    FaceDescriptor(vector: Float32List.fromList(values), revision: revision);

void main() {
  group('FaceDescriptor', () {
    test('cosine distance: 0 alike, ~1 unrelated, 2 opposite', () {
      final a = _of([1, 0, 0]);
      expect(a.distanceTo(a), closeTo(0, 1e-6));
      expect(a.distanceTo(_of([0, 1, 0])), closeTo(1, 1e-6));
      expect(a.distanceTo(_of([-1, 0, 0])), closeTo(2, 1e-6));
    });

    test('brightness is not identity: only direction counts', () {
      // The same face photographed darker is the same vector scaled. Plain
      // L2 called that a different person; the threshold guarding it had
      // no scale to be right about either.
      final a = _of([1, 2, 3]);
      expect(a.distanceTo(_of([2, 4, 6])), closeTo(0, 1e-6));
    });

    test('a direction that turns further is further away', () {
      final a = _of([1, 0, 0]);
      expect(
        a.distanceTo(_of([1, 0.2, 0]))!,
        lessThan(a.distanceTo(_of([1, 0.9, 0]))!),
      );
    });

    test('a vector with no direction cannot be compared', () {
      expect(_of([0, 0, 0]).distanceTo(_of([1, 0, 0])), isNull);
    });

    test('a descriptor from an older preprocessing step is stale', () {
      // Not a worse vector — one describing a different question. A print
      // of a colour crop and a print of a grey square don't belong in the
      // same space, so it is re-described rather than compared.
      final current = _of(
        [1, 0, 0],
        revision: FaceDescriptor.combineRevision(
          1,
          FaceDescriptor.currentPipeline,
        ),
      );
      expect(current.isStale, isFalse);
      expect(current.pipeline, FaceDescriptor.currentPipeline);

      final old = _of([
        1,
        0,
        0,
      ], revision: FaceDescriptor.combineRevision(1, 1));
      expect(old.isStale, isTrue);
      expect(current.distanceTo(old), isNull);
    });

    test('refuses to compare across revisions', () {
      // Not a worse answer — a different space. Comparing them would rank
      // an unrelated face above a real match with no way to tell.
      expect(_of([1, 0]).distanceTo(_of([1, 0], revision: 2)), isNull);
    });

    test('refuses a length mismatch or an empty one', () {
      expect(_of([1, 0]).distanceTo(_of([1, 0, 0])), isNull);
      expect(_of(const []).distanceTo(_of(const [])), isNull);
    });

    test('survives a round trip through storage', () {
      final original = _of([0.25, -1.5, 3]);
      final restored = FaceDescriptor.decode(original.encode(), 1);
      expect(restored.vector, original.vector);
      expect(original.distanceTo(restored), closeTo(0, 1e-6));
    });

    test('decodes nothing to an empty descriptor, not a crash', () {
      expect(FaceDescriptor.decode(null, 1).isEmpty, isTrue);
      expect(FaceDescriptor.decode(Uint8List(0), 1).isEmpty, isTrue);
    });
  });

  group('FaceCrops.descriptorRect', () {
    test('squares the box off and hugs it far tighter than the shown crop', () {
      final rect = FaceCrops.descriptorRect(const FaceRect(0.4, 0.4, 0.1, 0.2));
      expect(rect.width, rect.height, reason: 'square');
      expect(rect.width, closeTo(0.2 * 1.16, 0.0001));
      expect(rect.width, lessThan(0.2 * (1 + FaceCrops.padding * 2)));
      // Still centred on the face.
      expect(rect.x + rect.width / 2, closeTo(0.45, 0.0001));
      expect(rect.y + rect.height / 2, closeTo(0.5, 0.0001));
    });

    test('slides back inside the frame rather than spilling out', () {
      final rect = FaceCrops.descriptorRect(const FaceRect(0.0, 0.9, 0.2, 0.2));
      expect(rect.x, greaterThanOrEqualTo(0));
      expect(rect.y, greaterThanOrEqualTo(0));
      expect(rect.x + rect.width, lessThanOrEqualTo(1.0));
      expect(rect.y + rect.height, lessThanOrEqualTo(1.0));
    });

    test('a face filling the frame clamps to the frame', () {
      final rect = FaceCrops.descriptorRect(const FaceRect(0.0, 0.0, 1.0, 1.0));
      expect(rect.width, 1.0);
      expect(rect.x, 0.0);
    });
  });
}

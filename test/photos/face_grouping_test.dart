import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/face_grouping.dart';
import 'package:photos_vault/photos/on_device_vision.dart';
import 'package:photos_vault/photos/person.dart';

import '../support/fake_ai_analysis_store.dart';

void main() {
  late FakeAiAnalysisStore analyses;
  late FaceGrouping grouping;

  const face = FaceRect(0.3, 0.3, 0.4, 0.4);

  setUp(() {
    analyses = FakeAiAnalysisStore();
    grouping = FaceGrouping(analysisStore: analyses, ceiling: 0.3);
  });

  Future<void> describe(String id, List<double> v, {String? personId}) =>
      analyses.saveDescriptor(
        localId: id,
        face: face,
        personId: personId,
        descriptor: FaceDescriptor(
          vector: Float32List.fromList(v),
          revision: FaceDescriptor.combineRevision(
            1,
            FaceDescriptor.currentPipeline,
          ),
        ),
      );

  const seed = UnnamedFace(localId: 'a', face: face);

  test('gathers the faces that look like the seed, nearest first', () async {
    await describe('a', [1, 0, 0]);
    await describe('near', [1, 0.6, 0]);
    await describe('nearer', [1, 0.2, 0]);
    await describe('miles away', [0, 1, 0]);

    final group = await grouping.like(seed);

    expect(group.map((f) => f.localId), ['a', 'nearer', 'near']);
  });

  test('leaves out faces that already belong to somebody', () async {
    // They have an answer. Offering them again invites a second name on
    // the same face.
    await describe('a', [1, 0, 0]);
    await describe('taken', [1, 0.1, 0], personId: 'nina');

    final group = await grouping.like(seed);

    expect(group.map((f) => f.localId), ['a']);
  });

  test('a seed nothing has described yet groups nothing', () async {
    // Which means the analyze pass hasn't reached it — not that the
    // person is alone in the library.
    await describe('other', [1, 0, 0]);

    expect(await grouping.like(seed), isEmpty);
  });

  test('ignores descriptors from another Vision revision', () async {
    await describe('a', [1, 0, 0]);
    await analyses.saveDescriptor(
      localId: 'old',
      face: face,
      descriptor: FaceDescriptor(
        vector: Float32List.fromList(const [1, 0, 0]),
        revision: 2,
      ),
    );

    expect((await grouping.like(seed)).map((f) => f.localId), ['a']);
  });

  test('folding the list is stricter than showing a group', () {
    // A wrong face in a group is one tap to untick, because you can see
    // it. A wrong fold hides someone behind another circle, with nothing
    // on screen to correct — so the two cannot share a threshold.
    for (final pipeline in FaceGrouping.ceilingFor.keys) {
      expect(
        FaceGrouping.foldingCeilingForPipeline(pipeline),
        lessThan(FaceGrouping.ceilingForPipeline(pipeline)),
        reason: 'pipeline $pipeline',
      );
    }
  });

  test('an unknown space falls back to the strictest numbers', () {
    // Better to split one person in two than to merge two into one.
    expect(FaceGrouping.ceilingForPipeline(99), 0.30);
    expect(FaceGrouping.foldingCeilingForPipeline(99), 0.22);
  });

  test(
    'the group opens with what the circle counted, not a capped slice',
    () async {
      // A circle promising two hundred photos that opens on thirty-seven is
      // a lie told by the cap, and the two used different thresholds too.
      await describe('a', [1, 0, 0]);
      for (var i = 0; i < 60; i++) {
        await describe('near$i', [1, 0.01 * (i % 5 + 1), 0]);
      }

      final group = await FaceGrouping(analysisStore: analyses).like(seed);

      expect(group.length, 61, reason: 'not truncated at 40');
      expect(group.first.localId, 'a', reason: 'the seed leads');
    },
  );

  test(
    'searching from every confirmed face finds what one would miss',
    () async {
      // Christine face-on and Christine in profile are far apart as
      // vectors. A search from the face-on one alone misses the profile;
      // a search from both finds photos near either. This is the whole of
      // why tagging more pays off.
      await describe('face-on', [1, 0, 0], personId: 'nina');
      await describe('profile', [0, 1, 0], personId: 'nina');
      await describe('another face-on', [1, 0.05, 0]);
      await describe('another profile', [0.05, 1, 0]);
      await describe('somebody else', [0, 0, 1]);

      final grouping = FaceGrouping(analysisStore: analyses);
      final found = await grouping.likeAnyOf(await analyses.confirmedFaces());

      expect(found.map((f) => f.localId).toSet(), {
        'another face-on',
        'another profile',
      });
    },
  );

  test('with nobody confirmed there is nothing to search from', () async {
    await describe('a', [1, 0, 0]);
    expect(
      await FaceGrouping(analysisStore: analyses).likeAnyOf(const []),
      isEmpty,
    );
  });
}

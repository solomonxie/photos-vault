import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/face_identity.dart';
import 'package:photos_vault/photos/face_matcher.dart';
import 'package:photos_vault/photos/on_device_vision.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/storage/asset_record.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';

/// Vision, without Vision: a descriptor per path, set by the test.
class _FakeVision implements OnDeviceVisionService {
  final Map<String, List<double>> prints = {};
  int calls = 0;

  @override
  Future<FaceDescriptor> featurePrint(String path, {FaceRect? face}) async {
    calls++;
    return FaceDescriptor(
      vector: Float32List.fromList(prints[path] ?? const [0, 0, 0]),
      revision: _currentSpace,
    );
  }

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> get hasFaceModel async => false;

  @override
  Future<Object?> get faceModelStatus async => 'no model in tests';

  @override
  Future<List<VisionFace>> faces(String path) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The space this build describes faces in — a fake that answered from
/// another one would be re-described on sight, which is the point of it.
final _currentSpace = FaceDescriptor.combineRevision(
  1,
  FaceDescriptor.currentPipeline,
);

void main() {
  late FakeAssetRecordStore records;
  late FakeAiAnalysisStore analyses;
  late _FakeVision vision;
  late FaceIdentityService identity;

  const face = FaceRect(0.3, 0.3, 0.4, 0.4);

  setUp(() {
    records = FakeAssetRecordStore();
    analyses = FakeAiAnalysisStore();
    vision = _FakeVision();
    identity = FaceIdentityService(
      analysisStore: analyses,
      resolvePath: (r) async => '/tmp/${r.localId}.jpg',
      vision: vision,
      matcher: const FaceMatcher(ceiling: 0.3, margin: 0.1),
    );
  });

  Future<AssetRecord> photo(String id, List<double> descriptor) async {
    vision.prints['/tmp/$id.jpg'] = descriptor;
    return records.upsert(localId: id, contentHash: id, platform: 'ios');
  }

  test('naming one face lets the next photo be guessed', () async {
    final first = await photo('a', [1, 0, 0]);
    final second = await photo('b', [1, 0.05, 0]);

    await identity.remember(record: first, face: face, personId: 'nina');
    await identity.suggestFor(
      record: second,
      faces: const [face],
      confirmed: await analyses.confirmedFaces(),
    );

    final guesses = await analyses.suggestionsByAsset();
    expect(guesses['b']?[face.encode()], 'nina');
  });

  test('a stranger gets no name rather than the nearest one', () async {
    final known = await photo('a', [1, 0, 0]);
    final stranger = await photo('b', [0, 1, 0]);

    await identity.remember(record: known, face: face, personId: 'nina');
    await identity.suggestFor(
      record: stranger,
      faces: const [face],
      confirmed: await analyses.confirmedFaces(),
    );

    expect(await analyses.suggestionsByAsset(), isEmpty);
    // Recorded all the same, or the pass asks the same unanswerable
    // question of this photo forever.
    expect(await analyses.matchedAssets(), contains('b'));
  });

  test('with nobody named it still describes the face', () async {
    final only = await photo('a', [1, 0, 0]);

    await identity.suggestFor(
      record: only,
      faces: const [face],
      confirmed: const [],
    );

    // Nothing to compare against, so no guess — but the description is
    // what "who else looks like this?" searches, and it is the same
    // Vision pass either way.
    expect(vision.calls, 1);
    expect(await analyses.suggestionsByAsset(), isEmpty);
    expect(await analyses.matchedAssets(), contains('a'));
    expect((await analyses.descriptorFor('a', face))?.isEmpty, isFalse);
  });

  test('a face already described is not looked at twice', () async {
    final only = await photo('a', [1, 0, 0]);
    await identity.suggestFor(
      record: only,
      faces: const [face],
      confirmed: const [],
    );

    await identity.suggestFor(
      record: only,
      faces: const [face],
      confirmed: const [],
    );

    expect(vision.calls, 1, reason: 'one Vision pass per face, ever');
  });

  test('naming a described face costs no second look', () async {
    final only = await photo('a', [1, 0, 0]);
    await identity.suggestFor(
      record: only,
      faces: const [face],
      confirmed: const [],
    );

    await identity.remember(record: only, face: face, personId: 'nina');

    expect(vision.calls, 1);
    expect((await analyses.confirmedFaces()).single.personId, 'nina');
  });

  test(
    'the first face of a new person reopens every unanswered guess',
    () async {
      final looked = await photo('a', [1, 0, 0]);
      await identity.suggestFor(
        record: looked,
        faces: const [face],
        confirmed: const [],
      );
      expect(await analyses.matchedAssets(), isNotEmpty);

      await identity.remember(
        record: await photo('b', [1, 0, 0]),
        face: face,
        personId: 'nina',
      );

      // Everything the matcher had no opinion about was decided when there
      // was nobody to match against. Now there is someone.
      expect(await analyses.matchedAssets(), isEmpty);
    },
  );

  test('their second face does not re-run the library', () async {
    final one = await photo('a', [1, 0, 0]);
    final two = await photo('b', [1, 0, 0]);
    await identity.remember(record: one, face: face, personId: 'nina');

    final other = await photo('c', [0, 1, 0]);
    await identity.suggestFor(
      record: other,
      faces: const [face],
      confirmed: await analyses.confirmedFaces(),
    );
    await identity.remember(record: two, face: face, personId: 'nina');

    expect(
      await analyses.matchedAssets(),
      contains('c'),
      reason: 'a tenth photo of Nina changes almost nothing',
    );
  });

  test(
    'taking back one confirmation removes that face, not the person',
    () async {
      final first = await photo('a', [1, 0, 0]);
      final second = await photo('b', [1, 0, 0]);
      await identity.remember(record: first, face: face, personId: 'nina');
      await identity.remember(record: second, face: face, personId: 'nina');

      await identity.unremember(localId: 'b', face: face);

      // Undo that only unlinked the photo would leave the rejected face
      // pulling later photos towards the person it isn't.
      final left = await analyses.confirmedFaces();
      expect(left.map((f) => f.localId), ['a']);
    },
  );

  test('forgetting a person takes their faces with them', () async {
    final known = await photo('a', [1, 0, 0]);
    await identity.remember(record: known, face: face, personId: 'nina');

    await identity.forget('nina');

    expect(await analyses.confirmedFaces(), isEmpty);
  });
}

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/face_analyzer.dart';
import 'package:photos_vault/photos/face_identity.dart';
import 'package:photos_vault/photos/on_device_analysis.dart';
import 'package:photos_vault/photos/on_device_vision.dart';
import 'package:photos_vault/photos/person.dart' show FaceRect;
import 'package:photos_vault/storage/asset_record.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';

/// Vision, without Vision: every photo has one face in the middle of it.
class _FakeVision implements OnDeviceVisionService {
  int calls = 0;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<int?> orientation(String path) async => 1;

  @override
  Future<List<Uint8List>?> crops(
    String path,
    List<FaceRect> faces, {
    required double padding,
    required int side,
  }) async => null;

  @override
  Future<List<VisionFace>> faces(String path) async =>
      await facesOrNull(path) ?? const [];

  @override
  Future<List<VisionFace>?> facesOrNull(String source) async {
    calls++;
    return const [VisionFace(x: 0.3, y: 0.3, width: 0.4, height: 0.4)];
  }
}

void main() {
  late FakeAssetRecordStore records;
  late FakeAiAnalysisStore analyses;
  late _FakeVision vision;

  setUp(() {
    records = FakeAssetRecordStore();
    analyses = FakeAiAnalysisStore();
    vision = _FakeVision();
  });

  FaceAnalyzer build({
    Future<String?> Function(AssetRecord)? resolvePath,
    FaceIdentityService? identity,
    Future<List<String>> Function(String)? taggedPeopleOf,
  }) {
    final analyzer = FaceAnalyzer(
      assetRecordStore: records,
      analysisStore: analyses,
      onDeviceAnalysis: OnDeviceAnalysisService(
        analysisStore: analyses,
        vision: vision,
      ),
      resolvePath:
          resolvePath ?? (record) async => '/tmp/${record.localId}.jpg',
      faceIdentity: identity,
      taggedPeopleOf: taggedPeopleOf,
    );
    addTearDown(analyzer.dispose);
    return analyzer;
  }

  Future<void> addPhoto(String id) =>
      records.upsert(localId: id, contentHash: id, platform: 'ios');

  test(
    'each photo given is looked at once, and marked as having faces',
    () async {
      await addPhoto('a');
      await addPhoto('b');
      final analyzer = build();
      final done = <String>[];
      final sub = analyzer.finished.listen(done.add);
      addTearDown(sub.cancel);

      analyzer.add(['a', 'b', 'a']);
      await analyzer.idle;
      await Future<void>.delayed(Duration.zero);

      expect(done, ['a', 'b']);
      expect(vision.calls, 2);
      expect(analyzer.withFaces.value, {'a', 'b'});
    },
  );

  test('opening another photo queues it behind, never drops the one '
      'under way', () async {
    await addPhoto('a');
    await addPhoto('b');
    final gate = Completer<void>();
    final analyzer = build(
      resolvePath: (record) async {
        if (record.localId == 'a') await gate.future;
        return '/tmp/${record.localId}.jpg';
      },
    );

    analyzer.add(['a']);
    await Future<void>.delayed(Duration.zero);
    analyzer.add(['b']);
    gate.complete();
    await analyzer.idle;

    expect(await analyses.facesFor('a'), isNotEmpty);
    expect(await analyses.facesFor('b'), isNotEmpty);
  });

  test('a photo already analysed is not looked at again', () async {
    await addPhoto('a');
    final analyzer = build();
    analyzer.add(['a']);
    await analyzer.idle;
    analyzer.add(['a']);
    await analyzer.idle;
    expect(vision.calls, 1);
  });

  test('one it cannot open is skipped; the next still runs', () async {
    await addPhoto('stuck');
    await addPhoto('fine');
    final analyzer = build(
      resolvePath: (record) async =>
          record.localId == 'stuck' ? null : '/tmp/${record.localId}.jpg',
    );
    analyzer.add(['stuck', 'fine']);
    await analyzer.idle;
    expect(await analyses.facesFor('fine'), isNotEmpty);
    expect(analyzer.withFaces.value, {'fine'});
  });

  test('a photo of exactly one tagged person names its one face', () async {
    await addPhoto('a');
    final analyzer = build(
      identity: FaceIdentityService(analysisStore: analyses),
      taggedPeopleOf: (_) async => ['nina'],
    );
    analyzer.add(['a']);
    await analyzer.idle;
    expect(await analyses.faceOfPersonIn('a', 'nina'), isNotNull);
  });

  test('a photo found empty under the old cutoff is looked at again', () async {
    await addPhoto('old-empty');
    await addPhoto('new-empty');
    for (final (id, at) in [
      ('old-empty', DateTime(2026, 10, 1)),
      ('new-empty', DateTime(2026, 10, 25)),
    ]) {
      await analyses.saveFaceCount(localId: id, peopleCount: 0, analyzedAt: at);
    }
    final analyzer = build();
    analyzer.add(['old-empty', 'new-empty']);
    await analyzer.idle;
    expect(vision.calls, 1);
    expect(analyzer.withFaces.value, {'old-empty'});
  });

  test('the working set holds a photo until it is done', () async {
    await addPhoto('a');
    final gate = Completer<void>();
    final analyzer = build(
      resolvePath: (record) async {
        await gate.future;
        return '/tmp/a.jpg';
      },
    );
    analyzer.add(['a']);
    expect(analyzer.working.value, {'a'});
    gate.complete();
    await analyzer.idle;
    expect(analyzer.working.value, isEmpty);
  });

  test('which photos have faces is read back at start', () async {
    await analyses.saveFaceCount(
      localId: 'old',
      peopleCount: 1,
      analyzedAt: DateTime(2026),
      faces: const [FaceRect(0.1, 0.1, 0.2, 0.2)],
    );
    final analyzer = build();
    await analyzer.load();
    expect(analyzer.withFaces.value, {'old'});
  });
}

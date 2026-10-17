import 'dart:typed_data';

import 'package:photos_vault/photos/analyze_queue.dart';
import 'package:photos_vault/photos/face_identity.dart';
import 'package:photos_vault/photos/on_device_analysis.dart';
import 'package:photos_vault/photos/on_device_vision.dart';
import 'package:photos_vault/photos/person.dart' show FaceRect;
import 'package:photos_vault/settings/backup_targets_store.dart'
    show SyncFrequency;
import 'package:photos_vault/storage/asset_record.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';

/// Vision, without Vision: every photo has one face in the middle of it,
/// and a descriptor derived from the path so two photos never look alike
/// unless a test says so.
class _FakeVision implements OnDeviceVisionService {
  int calls = 0;
  final Map<String, List<double>> printsByPath = {};

  /// Which space prints come back in; the fallback's when the model is out.
  int pipeline = FaceDescriptor.currentPipeline;
  int printCalls = 0;

  @override
  Future<FaceDescriptor> featurePrint(String path, {FaceRect? face}) async {
    printCalls++;
    return FaceDescriptor(
      vector: Float32List.fromList(
        printsByPath[path] ?? [path.hashCode.toDouble()],
      ),
      revision: pipeline == FaceDescriptor.currentPipeline
          ? _currentSpace
          : FaceDescriptor.combineRevision(1, pipeline),
    );
  }

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> get hasFaceModel async => false;

  @override
  Future<Object?> get faceModelStatus async => 'no model in tests';

  @override
  Future<List<FaceDescriptor>> featurePrints(
    String path,
    List<FaceRect> faces,
  ) async => [for (final f in faces) await featurePrint(path, face: f)];

  @override
  Future<String?> get faceModelFailure async => modelFailure;

  String? modelFailure;

  @override
  Future<int?> orientation(String path) async => orientations[path] ?? 1;

  final Map<String, int> orientations = {};

  @override
  Future<List<Uint8List>?> crops(
    String path,
    List<FaceRect> faces, {
    required double padding,
    required int side,
  }) async => null;

  @override
  Future<List<VisionFace>> faces(String path) async {
    calls++;
    return const [VisionFace(x: 0.3, y: 0.3, width: 0.4, height: 0.4)];
  }

  /// Off: an older platform side, so [faces] answers and matching
  /// describes. On: one render answers both.
  bool combined = false;

  /// Sources the combined call was asked about.
  final combinedSources = <String>[];

  @override
  Future<List<({VisionFace face, FaceDescriptor print})>?> facesWithPrints(
    String source, {
    required double minArea,
    required double padding,
  }) async {
    if (!combined) return null;
    combinedSources.add(source);
    calls++;
    return [
      (
        face: const VisionFace(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
        print: FaceDescriptor(
          vector: Float32List.fromList(
            printsByPath[source] ?? [source.hashCode.toDouble()],
          ),
          revision: _currentSpace,
        ),
      ),
    ];
  }
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

  setUp(() {
    records = FakeAssetRecordStore();
    analyses = FakeAiAnalysisStore();
    vision = _FakeVision();
  });

  AnalyzeQueue build() {
    return AnalyzeQueue(
      assetRecordStore: records,
      analysisStore: analyses,
      onDeviceAnalysis: OnDeviceAnalysisService(
        analysisStore: analyses,
        vision: vision,
      ),
      resolvePath: (record) async => '/tmp/${record.localId}.jpg',
      displayNameFor: (record) => record.localId,
      rest: Duration.zero,
    );
  }

  Future<AssetRecord> addPhoto(String id, {DateTime? takenAt}) =>
      records.upsert(
        localId: id,
        contentHash: id,
        platform: 'ios',
        createdAt: takenAt,
      );

  test('clearing empties the list and stops, until resumed', () async {
    await addPhoto('photo:a', takenAt: DateTime(2026, 9));
    await addPhoto('photo:b', takenAt: DateTime(2026, 8));
    final queue = build();
    await queue.refresh();
    expect(queue.jobs.value, isNotEmpty);

    await queue.clear();

    // Emptied and stopped, rather than refilled in the same frame from the
    // library it's derived from — which would look like a button that
    // does nothing.
    expect(queue.jobs.value, isEmpty);
    expect(queue.paused.value, isTrue);
    await queue.refresh();
    expect(queue.jobs.value, isEmpty, reason: 'still empty while stopped');
    // The count is a fact about the library, not about the list on screen.
    expect(queue.remaining.value, 2);

    await queue.setPaused(false);
    await queue.start();

    expect(vision.calls, 2, reason: 'resuming is what picks the work back up');
  });

  test('a photo it cannot get to does not stall the whole pass', () async {
    await addPhoto('photo:stuck', takenAt: DateTime(2026, 9));
    await addPhoto('photo:fine', takenAt: DateTime(2026, 8));
    // Still in iCloud, so there's no file to look at — a skip, and the job
    // stays outstanding. The list is derived, so it comes straight back as
    // pending; without a guard the pass picks the same newest photo again
    // and never reaches the second one.
    final queue = AnalyzeQueue(
      assetRecordStore: records,
      analysisStore: analyses,
      onDeviceAnalysis: OnDeviceAnalysisService(
        analysisStore: analyses,
        vision: vision,
      ),
      resolvePath: (record) async =>
          record.localId == 'photo:stuck' ? null : '/tmp/${record.localId}.jpg',
      displayNameFor: (record) => record.localId,
      rest: Duration.zero,
    );

    await queue.start();

    expect(vision.calls, 1, reason: 'reached the photo it could open');
    expect(await analyses.facesFor('photo:fine'), isNotEmpty);
    // Left for a later pass rather than failed — but not retried on a
    // 400ms loop forever.
    expect(queue.remaining.value, 1);
  });

  test(
    'a rescan walks the whole library again; Empty Queue does not',
    () async {
      await addPhoto('photo:a', takenAt: DateTime(2026, 9));
      final queue = build();
      await queue.start();
      expect(vision.calls, 1);
      await queue.refresh();
      expect(queue.remaining.value, 0, reason: 'nothing left to look at');

      // Empty Queue drops a list. What the list is derived from — "this
      // photo has been looked at" — is untouched, so there is still nothing
      // owed.
      await queue.clear();
      await queue.setPaused(false);
      // Resuming starts a drain of its own; let it finish, or the rescan
      // below joins that one instead of opening a new pass.
      await queue.start();
      await queue.refresh();
      expect(queue.remaining.value, 0);
      expect(vision.calls, 1);

      await queue.rescanAll();
      // `rescanAll` kicks the drain off and returns — the button mustn't
      // block until the library is done. Joining it is the test's job.
      await queue.start();

      expect(vision.calls, 2, reason: 'looked at again');
    },
  );

  test('a photo is described as soon as its faces are found', () async {
    // Not three library-wide passes: all the faces, then all the
    // descriptions. On a real camera roll the second never started, so
    // nothing had a descriptor and no face could be grouped with another.
    await addPhoto('photo:old', takenAt: DateTime(2014, 6));
    await addPhoto('photo:new', takenAt: DateTime(2026, 9));
    final analysisStore = analyses;
    final queue = AnalyzeQueue(
      assetRecordStore: records,
      analysisStore: analysisStore,
      onDeviceAnalysis: OnDeviceAnalysisService(
        analysisStore: analysisStore,
        vision: vision,
      ),
      faceIdentity: FaceIdentityService(
        analysisStore: analysisStore,
        resolvePath: (r) async => '/tmp/${r.localId}.jpg',
        vision: vision,
      ),
      resolvePath: (r) async => '/tmp/${r.localId}.jpg',
      displayNameFor: (r) => r.localId,
      rest: Duration.zero,
    );

    await queue.start();

    final described = await analysisStore.allDescribedFaces();
    expect(
      described.map((f) => f.localId),
      containsAll(<String>['photo:new', 'photo:old']),
    );
  });

  group('one render per photo (BG-10)', () {
    AnalyzeQueue withIdentity({
      required Future<String?> Function(AssetRecord r) source,
    }) => AnalyzeQueue(
      assetRecordStore: records,
      analysisStore: analyses,
      onDeviceAnalysis: OnDeviceAnalysisService(
        analysisStore: analyses,
        vision: vision,
      ),
      faceIdentity: FaceIdentityService(
        analysisStore: analyses,
        resolvePath: source,
        vision: vision,
      ),
      resolvePath: (r) async => '/tmp/${r.localId}.jpg',
      resolveSource: source,
      displayNameFor: (r) => r.localId,
      rest: Duration.zero,
    );

    test('faces and their descriptors come from one call, and matching '
        'needs no second look', () async {
      vision.combined = true;
      await addPhoto('photo:a');
      final queue = withIdentity(
        source: (r) async => OnDeviceVisionService.assetSource('A'),
      );

      await queue.start();

      expect(vision.combinedSources, ['photokit:A']);
      expect(vision.printCalls, 0, reason: 'described in the same render');
      final described = await analyses.allDescribedFaces();
      expect(described.map((f) => f.localId), ['photo:a']);
      expect(queue.remaining.value, 0);
    });

    test(
      'an asset that would not render is a skip, never "no faces"',
      () async {
        vision.combined = false; // the platform answered nothing
        await addPhoto('photo:a');
        final queue = withIdentity(
          source: (r) async => OnDeviceVisionService.assetSource('A'),
        );

        await queue.start();

        expect(await analyses.listAll(), isEmpty);
        expect(queue.remaining.value, 1, reason: 'left for a later pass');
      },
    );

    test(
      'boxes from before upright keep the file they were measured on',
      () async {
        vision.combined = true;
        await addPhoto('photo:old');
        analyses.seedLegacy('photo:old', const [FaceRect(0.1, 0.2, 0.3, 0.4)]);
        vision.orientations['/tmp/photo:old.jpg'] = 6;
        final queue = withIdentity(
          source: (r) async => OnDeviceVisionService.assetSource('OLD'),
        );

        await queue.start();

        expect(vision.combinedSources, isEmpty);
        expect(await analyses.facesFor('photo:old'), [
          const FaceRect(0.1, 0.2, 0.3, 0.4).oriented(6),
        ]);
      },
    );
  });

  test('works through the newest photos first', () async {
    await addPhoto('photo:2014', takenAt: DateTime(2014, 6));
    await addPhoto('photo:now', takenAt: DateTime(2026, 9));
    await addPhoto('photo:2020', takenAt: DateTime(2020, 1));
    final queue = build();

    await queue.refresh();

    expect(queue.jobs.value.map((j) => j.localId), [
      'photo:now',
      'photo:2020',
      'photo:2014',
    ]);
  });

  test('looks at every photo it has not looked at', () async {
    await addPhoto('photo:a');
    await addPhoto('photo:b');
    final queue = build();

    await queue.start();

    expect(vision.calls, 2, reason: 'one look per photo');
    expect((await analyses.listAll()).keys, {'photo:a', 'photo:b'});
    expect(queue.remaining.value, 0);
  });

  test('re-reading the camera roll is not this queue\'s business', () async {
    // It lives in `library_scanner.dart`: nobody chose it, nobody pays for
    // it, and no pause switch may stop new photos arriving.
    await addPhoto('photo:a');
    final queue = build();

    await queue.start();

    expect(queue.jobs.value.every((job) => job.localId != null), isTrue);
  });

  test('a photo already looked at is not looked at twice', () async {
    await addPhoto('photo:a');
    final queue = build();
    await queue.start();
    expect(vision.calls, 1);

    await queue.start();

    expect(vision.calls, 1, reason: 'nothing new to look at');
  });

  test('paused means paused', () async {
    await addPhoto('photo:a');
    final queue = build();
    await queue.setPaused(true);

    await queue.start();

    expect(vision.calls, 0);
  });

  test('manual is the default, and means nothing runs unasked', () async {
    await addPhoto('photo:a');
    final queue = build();

    expect(queue.frequency.value, SyncFrequency.manual);

    await queue.startIfDue();
    expect(vision.calls, 0);

    await queue.start();
    expect(vision.calls, 1, reason: 'asked directly, it still runs');
  });

  test('a video has no still to look at', () async {
    await records.upsert(
      localId: 'photo:movie',
      contentHash: 'movie',
      platform: 'ios',
      isVideo: true,
    );
    final queue = build();

    await queue.start();

    expect(vision.calls, 0);
  });

  test('settings survive the queue that set them', () async {
    final queue = build();
    await queue.setPace(3);
    await queue.setFrequency(SyncFrequency.daily);
    await queue.setPaused(true);

    final reopened = build();
    await reopened.load();

    expect(reopened.pace.value, 3);
    expect(reopened.frequency.value, SyncFrequency.daily);
    expect(reopened.paused.value, isTrue);
  });

  group('WP12', () {
    AnalyzeQueue withFaces({
      Future<String?> Function(AssetRecord r)? resolve,
      Future<void> Function(String localId, int orientation)? onReoriented,
    }) {
      final path = resolve ?? (r) async => '/tmp/${r.localId}.jpg';
      return AnalyzeQueue(
        assetRecordStore: records,
        analysisStore: analyses,
        onDeviceAnalysis: OnDeviceAnalysisService(
          analysisStore: analyses,
          vision: vision,
          onReoriented: onReoriented,
        ),
        faceIdentity: FaceIdentityService(
          analysisStore: analyses,
          resolvePath: path,
          vision: vision,
        ),
        resolvePath: path,
        displayNameFor: (r) => r.localId,
        rest: Duration.zero,
      );
    }

    test('photos it cannot open never stall the older ones (05#6)', () async {
      // More stuck photos than the list holds, all newer than the one
      // that can be done.
      for (var i = 0; i < AnalyzeQueue.capacity + 10; i++) {
        await addPhoto('photo:cloud$i', takenAt: DateTime(2026, 9, 1, 0, i));
      }
      await addPhoto('photo:local', takenAt: DateTime(2010));
      final queue = withFaces(
        resolve: (r) async =>
            r.localId == 'photo:local' ? '/tmp/local.jpg' : null,
      );

      await queue.start();

      expect(await analyses.facesFor('photo:local'), isNotEmpty);
      expect(vision.calls, 1);
      expect(queue.remaining.value, AnalyzeQueue.capacity + 10);
      expect(
        queue.jobs.value.where((j) => j.status == AnalyzeJobStatus.skipped),
        isNotEmpty,
        reason: 'shown as skipped, not done',
      );
      expect(
        queue.jobs.value.any((j) => j.status == AnalyzeJobStatus.done),
        isTrue,
      );
    });

    test('without the face model the fallback is kept and reported, not '
        're-described every run (05#5)', () async {
      vision
        ..modelFailure = 'SFace.mlmodelc not in the bundle'
        ..pipeline = 3;
      await addPhoto('photo:a');
      final queue = withFaces();

      await queue.start();
      expect(queue.faceModelProblem.value, contains('SFace'));
      expect(vision.printCalls, 1);
      expect(queue.remaining.value, 0);

      await queue.start();
      expect(vision.printCalls, 1, reason: 'no endless re-describe');
      expect(queue.remaining.value, 0);

      // Model back: the fallback's faces are worth describing again.
      vision
        ..modelFailure = null
        ..pipeline = FaceDescriptor.currentPipeline;
      await queue.start();
      expect(queue.faceModelProblem.value, isNull);
      expect(vision.printCalls, 2);
    });

    test('old raw-buffer boxes are turned upright with their names and '
        'avatars (05#7)', () async {
      await addPhoto('photo:portrait');
      const raw = FaceRect(0.1, 0.2, 0.3, 0.4);
      analyses.seedLegacy('photo:portrait', const [raw]);
      await analyses.saveDescriptor(
        localId: 'photo:portrait',
        face: raw,
        personId: 'nina',
        descriptor: FaceDescriptor(
          vector: Float32List.fromList(const [1, 0]),
          revision: _currentSpace,
        ),
      );
      vision.orientations['/tmp/photo:portrait.jpg'] = 6;
      final reoriented = <(String, int)>[];
      final queue = withFaces(
        onReoriented: (id, o) async => reoriented.add((id, o)),
      );

      await queue.start();

      final upright = raw.oriented(6);
      expect(await analyses.facesFor('photo:portrait'), [upright]);
      expect(await analyses.faceOfPersonIn('photo:portrait', 'nina'), upright);
      expect(reoriented, [('photo:portrait', 6)]);
      expect(vision.calls, 0, reason: 'turned, not found again');
      expect((await analyses.get('photo:portrait'))!.legacyBoxes, isFalse);
    });
  });
}

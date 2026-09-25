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

  @override
  Future<FaceDescriptor> featurePrint(String path, {FaceRect? face}) async =>
      FaceDescriptor(
        vector: Float32List.fromList(
          printsByPath[path] ?? [path.hashCode.toDouble()],
        ),
        revision: _currentSpace,
      );

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> get hasFaceModel async => false;

  @override
  Future<Object?> get faceModelStatus async => 'no model in tests';

  @override
  Future<List<VisionFace>> faces(String path) async {
    calls++;
    return const [VisionFace(x: 0.3, y: 0.3, width: 0.4, height: 0.4)];
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
}

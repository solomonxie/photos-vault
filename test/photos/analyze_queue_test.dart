import 'dart:io';

import 'package:photos_vault/photos/ai_analysis.dart';
import 'package:photos_vault/photos/ai_vision_service.dart';
import 'package:photos_vault/photos/analyze_queue.dart';
import 'package:photos_vault/photos/on_device_analysis.dart';
import 'package:photos_vault/photos/on_device_vision.dart';
import 'package:photos_vault/settings/backup_targets_store.dart'
    show SyncFrequency;
import 'package:photos_vault/storage/asset_record.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';

/// Vision, without Vision: every photo has one face in the middle of it.
class _FakeVision implements OnDeviceVisionService {
  int calls = 0;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<List<VisionFace>> faces(String path) async {
    calls++;
    return const [VisionFace(x: 0.3, y: 0.3, width: 0.4, height: 0.4)];
  }
}

class _FakeAiVision implements AiVisionService {
  _FakeAiVision(this._answer);

  final AiPhotoAnalysis Function(String localId) _answer;
  int calls = 0;

  @override
  Future<AiPhotoAnalysis> analyze({
    required String localId,
    required File imageFile,
  }) async {
    calls++;
    return _answer(localId);
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

  AnalyzeQueue build({AiVisionService? aiVision, bool hasKey = false}) {
    return AnalyzeQueue(
      assetRecordStore: records,
      analysisStore: analyses,
      onDeviceAnalysis: OnDeviceAnalysisService(
        analysisStore: analyses,
        vision: vision,
      ),
      aiVision: aiVision,
      hasAiKey: () async => hasKey,
      resolvePath: (record) async => '/tmp/${record.localId}.jpg',
      displayNameFor: (record) => record.localId,
      rest: Duration.zero,
    );
  }

  Future<AssetRecord> addPhoto(String id) =>
      records.upsert(localId: id, contentHash: id, platform: 'ios');

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

  _FakeAiVision talkative() => _FakeAiVision(
    (localId) => AiPhotoAnalysis(
      localId: localId,
      peopleCount: 1,
      eventLabel: 'Beach day',
      analyzedAt: DateTime.now(),
      tags: const ['beach'],
      description: 'A day at the beach.',
    ),
  );

  test('the paid step is out until it is switched on', () async {
    await addPhoto('photo:a');
    final ai = talkative();
    final queue = build(aiVision: ai, hasKey: true);

    await queue.start();
    expect(ai.calls, 0, reason: 'off by default — it is the half that bills');

    await queue.setSuggest(true);
    await queue.start();

    expect(ai.calls, 1);
    final suggestion = (await analyses.unreviewed()).single;
    expect(suggestion.tags, ['beach']);
    expect(suggestion.description, 'A day at the beach.');
  });

  test('switched on with no key, nothing is spent', () async {
    await addPhoto('photo:a');
    final ai = talkative();
    final queue = build(aiVision: ai);

    await queue.setSuggest(true);
    await queue.start();

    expect(ai.calls, 0);
    expect(queue.canSuggest.value, isFalse);
  });

  test(
    'a photo the vendor had nothing to say about is never asked twice',
    () async {
      await addPhoto('photo:a');
      final ai = _FakeAiVision(
        (localId) => AiPhotoAnalysis(
          localId: localId,
          peopleCount: 0,
          eventLabel: '',
          analyzedAt: DateTime.now(),
        ),
      );
      final queue = build(aiVision: ai, hasKey: true);
      await queue.setSuggest(true);

      await queue.start();
      expect(ai.calls, 1);
      expect(await analyses.unreviewed(), isEmpty);

      await queue.start();

      expect(
        ai.calls,
        1,
        reason:
            'paying twice for the same "no" is the one '
            'thing a queue that spends money must not do',
      );
    },
  );

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

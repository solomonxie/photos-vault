import 'package:bring_your_own_photos/photos/on_device_analysis.dart';
import 'package:bring_your_own_photos/photos/on_device_vision.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';

/// Stands in for `VisionAnalysisChannel.swift`: the same shapes the
/// platform hands back, without the platform.
MethodChannel _channelReturning({
  List<Map<String, Object?>> labels = const [],
  List<Map<String, Object?>> faces = const [],
}) {
  const channel = MethodChannel(OnDeviceVisionService.channelName);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        channel,
        (call) async => switch (call.method) {
          'classify' => labels,
          'faces' => faces,
          _ => null,
        },
      );
  return channel;
}

Map<String, Object?> _label(String label, double confidence) => {
  'label': label,
  'confidence': confidence,
};

Map<String, Object?> _face(double size) => {
  'x': 0.1,
  'y': 0.1,
  'width': size,
  'height': size,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AssetRecord> seed(FakeAssetRecordStore store) => store.upsert(
    localId: 'manual:a',
    contentHash: 'a',
    platform: 'ios',
    sourceType: AssetSourceType.manualFile,
    sourcePath: '/tmp/a.jpg',
  );

  group('tags', () {
    test('confident labels become tags', () async {
      final store = FakeAssetRecordStore();
      final record = await seed(store);
      final service = OnDeviceAnalysisService(
        recordStore: store,
        analysisStore: FakeAiAnalysisStore(),
        vision: OnDeviceVisionService(
          channel: _channelReturning(
            labels: [_label('beach', 0.9), _label('sunset', 0.7)],
          ),
        ),
      );

      await service.analyze(record, '/tmp/a.jpg');
      expect((await store.getByLocalId('manual:a'))!.tags, ['beach', 'sunset']);
    });

    test('unconfident guesses are not tags', () async {
      final store = FakeAssetRecordStore();
      final record = await seed(store);
      final service = OnDeviceAnalysisService(
        recordStore: store,
        analysisStore: FakeAiAnalysisStore(),
        vision: OnDeviceVisionService(
          channel: _channelReturning(
            labels: [_label('beach', 0.9), _label('llama', 0.05)],
          ),
        ),
      );

      await service.analyze(record, '/tmp/a.jpg');

      expect((await store.getByLocalId('manual:a'))!.tags, ['beach']);
    });

    test('labels true of half a camera roll are dropped', () async {
      final store = FakeAssetRecordStore();
      final record = await seed(store);
      final service = OnDeviceAnalysisService(
        recordStore: store,
        analysisStore: FakeAiAnalysisStore(),
        vision: OnDeviceVisionService(
          channel: _channelReturning(
            labels: [
              _label('outdoor', 0.99),
              _label('plant', 0.95),
              _label('tulip', 0.8),
            ],
          ),
        ),
      );

      await service.analyze(record, '/tmp/a.jpg');

      expect((await store.getByLocalId('manual:a'))!.tags, ['tulip']);
    });

    test("a tag the user typed is never dropped by a later pass", () async {
      final store = FakeAssetRecordStore();
      final record = await seed(store);
      await store.setTags('manual:a', ['Nina']);
      final service = OnDeviceAnalysisService(
        recordStore: store,
        analysisStore: FakeAiAnalysisStore(),
        vision: OnDeviceVisionService(
          channel: _channelReturning(labels: [_label('beach', 0.9)]),
        ),
      );

      await service.analyze(
        (await store.getByLocalId('manual:a'))!,
        '/tmp/a.jpg',
      );

      expect((await store.getByLocalId('manual:a'))!.tags, ['Nina', 'beach']);
    });

    test('tagging with everything it saw is the same as not tagging', () async {
      final store = FakeAssetRecordStore();
      final record = await seed(store);
      final service = OnDeviceAnalysisService(
        recordStore: store,
        analysisStore: FakeAiAnalysisStore(),
        vision: OnDeviceVisionService(
          channel: _channelReturning(
            labels: [for (var i = 0; i < 12; i++) _label('label$i', 0.9)],
          ),
        ),
      );

      await service.analyze(record, '/tmp/a.jpg');

      expect(
        (await store.getByLocalId('manual:a'))!.tags,
        hasLength(OnDeviceAnalysisService.maxTags),
      );
    });
  });

  group('faces', () {
    test('counts the ones big enough to be the subject', () async {
      final store = FakeAssetRecordStore();
      final analysis = FakeAiAnalysisStore();
      final record = await seed(store);
      final service = OnDeviceAnalysisService(
        recordStore: store,
        analysisStore: analysis,
        vision: OnDeviceVisionService(
          channel: _channelReturning(
            labels: [_label('portrait', 0.9)],
            faces: [_face(0.3), _face(0.2)],
          ),
        ),
      );

      await service.analyze(record, '/tmp/a.jpg');

      final saved = (await analysis.listAll())['manual:a']!;
      expect(saved.peopleCount, 2);
      expect(saved.eventLabel, 'portrait');
    });

    test('a crowd in the background is not people in the photo', () async {
      final store = FakeAssetRecordStore();
      final analysis = FakeAiAnalysisStore();
      final record = await seed(store);
      final service = OnDeviceAnalysisService(
        recordStore: store,
        analysisStore: analysis,
        vision: OnDeviceVisionService(
          channel: _channelReturning(
            labels: [_label('stadium', 0.9)],
            faces: [_face(0.3), for (var i = 0; i < 40; i++) _face(0.01)],
          ),
        ),
      );

      await service.analyze(record, '/tmp/a.jpg');

      expect((await analysis.listAll())['manual:a']!.peopleCount, 1);
    });
  });

  test('a photo Vision had nothing to say about is left alone', () async {
    final store = FakeAssetRecordStore();
    final analysis = FakeAiAnalysisStore();
    final record = await seed(store);
    final service = OnDeviceAnalysisService(
      recordStore: store,
      analysisStore: analysis,
      vision: OnDeviceVisionService(channel: _channelReturning()),
    );

    expect(await service.analyze(record, '/tmp/a.jpg'), isEmpty);
    expect(await analysis.listAll(), isEmpty);
    expect((await store.getByLocalId('manual:a'))!.tags, isEmpty);
  });

  test('no platform channel means no tags, not an error', () async {
    final store = FakeAssetRecordStore();
    final record = await seed(store);
    final service = OnDeviceAnalysisService(
      recordStore: store,
      analysisStore: FakeAiAnalysisStore(),
      vision: OnDeviceVisionService(
        channel: const MethodChannel('byo.photos/absent'),
      ),
    );

    expect(await service.analyze(record, '/tmp/a.jpg'), isEmpty);
  });

  test('the faces it found come back, to be put names to', () async {
    final store = FakeAssetRecordStore();
    final record = await seed(store);
    final service = OnDeviceAnalysisService(
      recordStore: store,
      analysisStore: FakeAiAnalysisStore(),
      vision: OnDeviceVisionService(
        channel: _channelReturning(faces: [_face(0.3), _face(0.001)]),
      ),
    );

    final faces = await service.analyze(record, '/tmp/a.jpg');

    // The speck in the background isn't a face anyone wants to tag.
    expect(faces, hasLength(1));
  });
}

import 'package:bring_your_own_photos/photos/on_device_analysis.dart';
import 'package:bring_your_own_photos/photos/on_device_vision.dart';
import 'package:bring_your_own_photos/storage/asset_record.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_ai_analysis_store.dart';
import '../support/fake_asset_record_store.dart';

/// Stands in for `VisionAnalysisChannel.swift`: the same shapes the
/// platform hands back, without the platform.
MethodChannel _channelReturning({List<Map<String, Object?>> faces = const []}) {
  const channel = MethodChannel(OnDeviceVisionService.channelName);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'faces' ? faces : null,
      );
  return channel;
}

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

  test('hands back the faces it found, to be put names to', () async {
    final store = FakeAssetRecordStore();
    final analysis = FakeAiAnalysisStore();
    final record = await seed(store);
    final service = OnDeviceAnalysisService(
      analysisStore: analysis,
      vision: OnDeviceVisionService(
        channel: _channelReturning(faces: [_face(0.3), _face(0.2)]),
      ),
    );

    final faces = await service.analyze(record, '/tmp/a.jpg');

    expect(faces, hasLength(2));
    expect((await analysis.listAll())['manual:a']!.peopleCount, 2);
  });

  test('a crowd in the background is not people in the photo', () async {
    final store = FakeAssetRecordStore();
    final analysis = FakeAiAnalysisStore();
    final record = await seed(store);
    final service = OnDeviceAnalysisService(
      analysisStore: analysis,
      vision: OnDeviceVisionService(
        channel: _channelReturning(
          faces: [_face(0.3), for (var i = 0; i < 40; i++) _face(0.01)],
        ),
      ),
    );

    await service.analyze(record, '/tmp/a.jpg');

    expect((await analysis.listAll())['manual:a']!.peopleCount, 1);
  });

  test('it never touches tags — those are the vendor models\' job', () async {
    final store = FakeAssetRecordStore();
    final record = await seed(store);
    await store.setTags('manual:a', ['Nina']);
    final service = OnDeviceAnalysisService(
      analysisStore: FakeAiAnalysisStore(),
      vision: OnDeviceVisionService(
        channel: _channelReturning(faces: [_face(0.3)]),
      ),
    );

    await service.analyze(record, '/tmp/a.jpg');

    expect((await store.getByLocalId('manual:a'))!.tags, ['Nina']);
  });

  test('a photo with no faces saves nothing', () async {
    final store = FakeAssetRecordStore();
    final analysis = FakeAiAnalysisStore();
    final record = await seed(store);
    final service = OnDeviceAnalysisService(
      analysisStore: analysis,
      vision: OnDeviceVisionService(channel: _channelReturning()),
    );

    expect(await service.analyze(record, '/tmp/a.jpg'), isEmpty);
    expect(await analysis.listAll(), isEmpty);
  });

  test('no platform channel means no faces, not an error', () async {
    final store = FakeAssetRecordStore();
    final record = await seed(store);
    final service = OnDeviceAnalysisService(
      analysisStore: FakeAiAnalysisStore(),
      vision: OnDeviceVisionService(
        channel: const MethodChannel('byo.photos/absent'),
      ),
    );

    expect(await service.analyze(record, '/tmp/a.jpg'), isEmpty);
  });
}

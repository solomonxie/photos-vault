import 'dart:convert';
import 'dart:io';

import 'package:back_your_own_photos/photos/ai_vision_service.dart';
import 'package:back_your_own_photos/settings/ai_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../settings/fake_secure_store.dart';

void main() {
  late Directory tempDir;
  late File imageFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ai_vision_service_test');
    imageFile = File('${tempDir.path}/photo.jpg')..writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() => tempDir.delete(recursive: true));

  AiVisionService serviceWith({String? apiKey, required http.Client httpClient}) {
    final secureStore = FakeSecureStore();
    if (apiKey != null) secureStore.seed('openai_api_key_v1', apiKey);
    return AiVisionService(aiSettingsStore: AiSettingsStore(store: secureStore), httpClient: httpClient);
  }

  String successBody(Map<String, dynamic> content) => jsonEncode({
    'choices': [
      {
        'message': {'content': jsonEncode(content)},
      },
    ],
  });

  test('throws when no API key is configured', () async {
    final service = serviceWith(httpClient: MockClient((_) async => http.Response('', 200)));

    await expectLater(service.analyze(localId: 'p1', imageFile: imageFile), throwsA(isA<AiAnalysisException>()));
  });

  test('sends the image and key, and parses a successful response', () async {
    late http.Request captured;
    final service = serviceWith(
      apiKey: 'sk-test',
      httpClient: MockClient((request) async {
        captured = request;
        return http.Response(successBody({'people_count': 2, 'event_label': 'Birthday party'}), 200);
      }),
    );

    final result = await service.analyze(localId: 'p1', imageFile: imageFile);

    expect(result.localId, 'p1');
    expect(result.peopleCount, 2);
    expect(result.eventLabel, 'Birthday party');
    expect(captured.headers['Authorization'], 'Bearer sk-test');
    expect(captured.body, contains(base64Encode([1, 2, 3])));
  });

  test('defaults to 0 people and an empty label when fields are missing', () async {
    final service = serviceWith(apiKey: 'sk-test', httpClient: MockClient((_) async => http.Response(successBody({}), 200)));

    final result = await service.analyze(localId: 'p1', imageFile: imageFile);

    expect(result.peopleCount, 0);
    expect(result.eventLabel, '');
  });

  test('throws on a non-200 response', () async {
    final service = serviceWith(apiKey: 'sk-test', httpClient: MockClient((_) async => http.Response('bad key', 401)));

    await expectLater(service.analyze(localId: 'p1', imageFile: imageFile), throwsA(isA<AiAnalysisException>()));
  });

  test('throws when the response body is not the expected shape', () async {
    final service = serviceWith(apiKey: 'sk-test', httpClient: MockClient((_) async => http.Response('not json', 200)));

    await expectLater(service.analyze(localId: 'p1', imageFile: imageFile), throwsA(isA<AiAnalysisException>()));
  });
}

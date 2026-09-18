import 'dart:convert';
import 'dart:io';

import 'package:photos_vault/photos/ai_vendor.dart';
import 'package:photos_vault/photos/ai_vision_service.dart';
import 'package:photos_vault/settings/ai_settings_store.dart';
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

  Future<AiVisionService> serviceWith({
    AiVendor? vendor,
    String? apiKey,
    required http.Client httpClient,
  }) async {
    final aiSettingsStore = AiSettingsStore(store: FakeSecureStore());
    if (apiKey != null) {
      await aiSettingsStore.addKey(vendor ?? AiVendor.openai, apiKey);
    }
    return AiVisionService(
      aiSettingsStore: aiSettingsStore,
      httpClient: httpClient,
    );
  }

  String openAiSuccessBody(Map<String, dynamic> content) => jsonEncode({
    'choices': [
      {
        'message': {'content': jsonEncode(content)},
      },
    ],
  });

  String anthropicSuccessBody(Map<String, dynamic> content) => jsonEncode({
    'content': [
      {'text': jsonEncode(content)},
    ],
  });

  String googleSuccessBody(Map<String, dynamic> content) => jsonEncode({
    'candidates': [
      {
        'content': {
          'parts': [
            {'text': jsonEncode(content)},
          ],
        },
      },
    ],
  });

  test('throws when no AI key is configured', () async {
    final service = await serviceWith(
      httpClient: MockClient((_) async => http.Response('', 200)),
    );

    await expectLater(
      service.analyze(localId: 'p1', imageFile: imageFile),
      throwsA(isA<AiAnalysisException>()),
    );
  });

  test(
    'sends the image and key to OpenAI, and parses a successful response',
    () async {
      late http.Request captured;
      final service = await serviceWith(
        apiKey: 'sk-test',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            openAiSuccessBody({
              'people_count': 2,
              'event_label': 'Birthday party',
            }),
            200,
          );
        }),
      );

      final result = await service.analyze(localId: 'p1', imageFile: imageFile);

      expect(result.localId, 'p1');
      expect(result.peopleCount, 2);
      expect(result.eventLabel, 'Birthday party');
      expect(captured.headers['Authorization'], 'Bearer sk-test');
      expect(captured.body, contains(base64Encode([1, 2, 3])));
    },
  );

  test(
    'sends the image and key to Anthropic, and parses its response shape',
    () async {
      late http.Request captured;
      final service = await serviceWith(
        vendor: AiVendor.anthropic,
        apiKey: 'sk-ant-test',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            anthropicSuccessBody({'people_count': 1, 'event_label': 'Hiking'}),
            200,
          );
        }),
      );

      final result = await service.analyze(localId: 'p1', imageFile: imageFile);

      expect(result.peopleCount, 1);
      expect(result.eventLabel, 'Hiking');
      expect(captured.headers['x-api-key'], 'sk-ant-test');
    },
  );

  test(
    'sends the image and key to Google, and parses its response shape',
    () async {
      late http.Request captured;
      final service = await serviceWith(
        vendor: AiVendor.google,
        apiKey: 'AIza-test',
        httpClient: MockClient((request) async {
          captured = request;
          return http.Response(
            googleSuccessBody({'people_count': 3, 'event_label': 'Wedding'}),
            200,
          );
        }),
      );

      final result = await service.analyze(localId: 'p1', imageFile: imageFile);

      expect(result.peopleCount, 3);
      expect(result.eventLabel, 'Wedding');
      expect(captured.url.toString(), contains('key=AIza-test'));
    },
  );

  test(
    'defaults to 0 people and an empty label when fields are missing',
    () async {
      final service = await serviceWith(
        apiKey: 'sk-test',
        httpClient: MockClient(
          (_) async => http.Response(openAiSuccessBody({}), 200),
        ),
      );

      final result = await service.analyze(localId: 'p1', imageFile: imageFile);

      expect(result.peopleCount, 0);
      expect(result.eventLabel, '');
    },
  );

  test('throws on a non-200 response', () async {
    final service = await serviceWith(
      apiKey: 'sk-test',
      httpClient: MockClient((_) async => http.Response('bad key', 401)),
    );

    await expectLater(
      service.analyze(localId: 'p1', imageFile: imageFile),
      throwsA(isA<AiAnalysisException>()),
    );
  });

  test('throws when the response body is not the expected shape', () async {
    final service = await serviceWith(
      apiKey: 'sk-test',
      httpClient: MockClient((_) async => http.Response('not json', 200)),
    );

    await expectLater(
      service.analyze(localId: 'p1', imageFile: imageFile),
      throwsA(isA<AiAnalysisException>()),
    );
  });

  test('falls back to the next key when the first one fails', () async {
    final aiSettingsStore = AiSettingsStore(store: FakeSecureStore());
    await aiSettingsStore.addKey(AiVendor.openai, 'sk-bad');
    await aiSettingsStore.addKey(AiVendor.anthropic, 'sk-ant-good');
    var calls = 0;
    final service = AiVisionService(
      aiSettingsStore: aiSettingsStore,
      httpClient: MockClient((request) async {
        calls++;
        if (request.url.host.contains('openai')) {
          return http.Response('rejected', 401);
        }
        return http.Response(
          anthropicSuccessBody({'people_count': 5, 'event_label': 'Reunion'}),
          200,
        );
      }),
    );

    final result = await service.analyze(localId: 'p1', imageFile: imageFile);

    expect(calls, 2);
    expect(result.peopleCount, 5);
    expect(result.eventLabel, 'Reunion');
  });
}

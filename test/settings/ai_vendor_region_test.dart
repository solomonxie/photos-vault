import 'package:photos_vault/photos/ai_vendor.dart';
import 'package:photos_vault/settings/ai_settings_store.dart';
import 'package:photos_vault/settings/app_store_region.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:photos_vault/photos/ai_chat.dart';

import 'fake_secure_store.dart';

void main() {
  test('the China storefront offers no AI at all, for now', () {
    expect(aiVendorsFor(AppStoreRegion.cn), isEmpty);
    expect(
      aiVendorsFor(AppStoreRegion.us).map((v) => v.vendor),
      isNot(contains(AiVendor.qwen)),
    );
  });

  test('in China, stored keys are kept but never used', () async {
    final secure = FakeSecureStore();
    await AiSettingsStore(
      store: secure,
      fixedRegion: AppStoreRegion.us,
    ).addKey(AiVendor.openai, 'sk-us');
    final cn = AiSettingsStore(store: secure, fixedRegion: AppStoreRegion.cn);

    expect((await cn.listKeys()).length, 1);
    expect(await cn.usableKeys(), isEmpty);
    final used = <String>[];
    await expectLater(
      cn.runWithKeys((k) async => used.add(k.secret)),
      throwsA(anything),
    );
    expect(used, isEmpty);
  });

  test('a key for a vendor this build no longer has is skipped', () async {
    final secure = FakeSecureStore();
    await secure.write(
      'ai_keys_v1',
      '[{"id":"1","vendor":"custom","secret":"x"},'
          '{"id":"2","vendor":"qwen","secret":"y"}]',
    );
    final keys = await AiSettingsStore(store: secure).listKeys();
    expect(keys.single.vendor, AiVendor.qwen);
  });

  test('DeepSeek asks deepseek-v4-pro in plain text', () async {
    late Map<String, dynamic> sent;
    final client = MockClient((request) async {
      sent = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'OK'},
            },
          ],
        }),
        200,
      );
    });
    await checkVendorKey(
      vendor: AiVendor.deepseek,
      apiKey: 'sk',
      client: client,
    );
    expect(sent['model'], 'deepseek-v4-pro');
    expect(sent['messages'][0]['content'], isA<String>());
  });

  test('a request that never answers times out', () async {
    final client = MockClient((_) => Completer<http.Response>().future);
    await expectLater(
      askVendor(
        vendor: AiVendor.deepseek,
        apiKey: 'sk',
        prompt: 'p',
        client: client,
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(isA<AiChatException>()),
    );
  });

  test('the Gemini key goes in a header, never the URL (05#25)', () async {
    late http.Request sent;
    final client = MockClient((request) async {
      sent = request;
      return http.Response(
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'OK'},
                ],
              },
            },
          ],
        }),
        200,
      );
    });

    await checkVendorKey(
      vendor: AiVendor.google,
      apiKey: 'AIza-secret',
      client: client,
    );

    expect(sent.url.toString(), isNot(contains('AIza-secret')));
    expect(sent.url.path, contains('gemini-2.5-flash'));
    expect(sent.headers['x-goog-api-key'], 'AIza-secret');
  });

  test('a vendor\'s own reason is shown with the status (05#20)', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'error': {'message': 'The model  `x` has\nbeen deprecated'},
        }),
        404,
      ),
    );

    await expectLater(
      askVendor(
        vendor: AiVendor.openai,
        apiKey: 'sk',
        prompt: 'p',
        client: client,
      ),
      throwsA(
        isA<AiChatException>().having(
          (e) => e.message,
          'message',
          'OpenAI request failed (404): The model `x` has been deprecated',
        ),
      ),
    );
  });

  test('key edits and request counts never lose each other (05#25)', () async {
    final secure = FakeSecureStore();
    final store = AiSettingsStore(
      store: secure,
      fixedRegion: AppStoreRegion.us,
    );
    final first = await store.addKey(AiVendor.openai, 'sk-1');

    await Future.wait([
      store.runWithKeys((_) async => 'ok'),
      store.addKey(AiVendor.anthropic, 'sk-2'),
      AiSettingsStore(
        store: secure,
        fixedRegion: AppStoreRegion.us,
      ).addKey(AiVendor.groq, 'sk-3'),
      store.runWithKeys((_) async => 'ok'),
    ]);

    final keys = await store.listKeys();
    expect(
      keys.map((k) => k.secret),
      unorderedEquals(['sk-1', 'sk-2', 'sk-3']),
    );
    expect(keys.firstWhere((k) => k.id == first).requestCount, 2);
  });
}

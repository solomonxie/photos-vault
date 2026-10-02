import 'package:photos_vault/photos/ai_vendor.dart';
import 'package:photos_vault/settings/ai_settings_store.dart';
import 'package:photos_vault/settings/app_store_region.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:photos_vault/photos/ai_chat.dart';

import 'fake_secure_store.dart';

void main() {
  test('the China storefront offers only China vendors', () {
    expect(aiVendorsFor(AppStoreRegion.cn).map((v) => v.vendor), [
      AiVendor.deepseek,
      AiVendor.qwen,
      AiVendor.zhipu,
      AiVendor.moonshot,
    ]);
    expect(
      aiVendorsFor(AppStoreRegion.us).map((v) => v.vendor),
      isNot(contains(AiVendor.qwen)),
    );
  });

  test('keys for the other storefront are kept but never used', () async {
    final secure = FakeSecureStore();
    await AiSettingsStore(
      store: secure,
      fixedRegion: AppStoreRegion.us,
    ).addKey(AiVendor.openai, 'sk-us');
    final cn = AiSettingsStore(store: secure, fixedRegion: AppStoreRegion.cn);
    await cn.addKey(AiVendor.qwen, 'sk-cn');

    expect((await cn.listKeys()).length, 2);
    expect((await cn.usableKeys()).single.vendor, AiVendor.qwen);
    final used = <String>[];
    await cn.runWithKeys((k) async => used.add(k.secret));
    expect(used, ['sk-cn']);
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

  test(
    'DeepSeek asks deepseek-v4-pro in plain text, and refuses photos',
    () async {
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

      expect(
        askVendor(
          vendor: AiVendor.deepseek,
          apiKey: 'sk',
          prompt: 'p',
          client: client,
          image: Uint8List(1),
        ),
        throwsA(isA<AiChatException>()),
      );
    },
  );

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
}

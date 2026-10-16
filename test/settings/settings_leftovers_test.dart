import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/l10n/failure_text.dart';
import 'package:photos_vault/photos/ai_vendor.dart';
import 'package:photos_vault/settings/ai_settings_store.dart';
import 'package:photos_vault/settings/app_store_region.dart';
import 'package:photos_vault/settings/s3_target_drafts_store.dart';

import 'fake_secure_store.dart';

/// Counts writes, to prove a read leaves the keychain alone.
class _CountingStore extends FakeSecureStore {
  var writes = 0;

  @override
  Future<void> write(String key, String value) {
    writes++;
    return super.write(key, value);
  }
}

void main() {
  group('AI keys', () {
    test('reading no keys writes nothing', () async {
      final secure = _CountingStore();
      final store = AiSettingsStore(store: secure);
      expect(await store.listKeys(), isEmpty);
      expect(await store.listKeys(), isEmpty);
      expect(secure.writes, 0);
    });

    test('an unreadable key list reads as none, not a crash', () async {
      final secure = FakeSecureStore()..seed('ai_keys_v1', '{not json');
      expect(await AiSettingsStore(store: secure).listKeys(), isEmpty);
    });

    test('moving a key steps over one this storefront hides', () async {
      final secure = FakeSecureStore();
      final store = AiSettingsStore(
        store: secure,
        fixedRegion: AppStoreRegion.us,
      );
      final a = await store.addKey(AiVendor.openai, 'a');
      await store.addKey(AiVendor.deepseek, 'hidden');
      final c = await store.addKey(AiVendor.anthropic, 'c');

      await store.moveKey(c, -1);
      expect(
        [for (final k in await store.listKeys()) k.secret],
        ['c', 'hidden', 'a'],
      );
      expect([for (final k in await store.usableKeys()) k.id], [c, a]);

      await store.moveKey(c, -1);
      expect((await store.listKeys()).first.id, c);
    });
  });

  group('drafts', () {
    var now = DateTime.utc(2026, 10, 1);
    S3TargetDraftsStore drafts(FakeSecureStore secure) =>
        S3TargetDraftsStore(store: secure, now: () => now);

    Future<void> save(S3TargetDraftsStore store, String bucket) => store.save(
      accessKeyId: 'AK',
      secretAccessKey: 'secret-$bucket',
      bucket: bucket,
      prefix: '',
    );

    setUp(() => now = DateTime.utc(2026, 10, 1));

    test('only the newest three are kept', () async {
      final store = drafts(FakeSecureStore());
      for (final b in ['b1', 'b2', 'b3', 'b4']) {
        now = now.add(const Duration(minutes: 1));
        await save(store, b);
      }
      expect(
        [for (final d in await store.loadAll()) d.bucket],
        ['b2', 'b3', 'b4'],
      );
    });

    test('a draft older than 30 days is gone, secret and all', () async {
      final secure = FakeSecureStore();
      final store = drafts(secure);
      await save(store, 'old');
      now = now.add(const Duration(days: 31));
      expect(await store.loadAll(), isEmpty);
      expect(await secure.read('s3_target_drafts_v1'), '[]');
    });

    test('undated drafts from before are kept and dated, never ahead of '
        'the one being saved', () async {
      final secure = FakeSecureStore()
        ..seed(
          's3_target_drafts_v1',
          '[{"id":"1","bucket":"l1"},{"id":"2","bucket":"l2"},'
              '{"id":"3","bucket":"l3"}]',
        );
      final store = drafts(secure);
      expect(await store.loadAll(), hasLength(3));
      await save(store, 'new');
      final kept = await store.loadAll();
      expect(kept, hasLength(3));
      expect(kept.map((d) => d.bucket), contains('new'));
      expect(kept.every((d) => d.savedAt != null), isTrue);
    });
  });

  group('failure text', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('never shows a URL, whose query can carry a key', () {
      final text = failureText(
        l10n,
        Exception(
          'Bad request, uri=https://example.com/v1?key=SECRET123 at line 1',
        ),
      );
      expect(text, isNot(contains('SECRET123')));
      expect(text, isNot(contains('https://')));
      expect(text, contains('Bad request'));
    });

    test('no key and no network read as what they are', () {
      expect(failureText(l10n, NoAiKeyException()), l10n.askAiNoKey);
      for (final error in <Object>[
        const SocketException('down'),
        http.ClientException('x', Uri.parse('https://h/?key=SECRET')),
        TimeoutException('slow'),
      ]) {
        expect(failureText(l10n, error), l10n.errorOffline);
      }
    });
  });
}

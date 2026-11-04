// ignore_for_file: avoid_print
// Run through `flutter test` (the app's sync code needs Flutter's
// libraries); see README.md. Every renamed upload in $WORK/renamed.jsonl
// becomes an `asset` add in the cloud log, from a device of its own, so
// each phone makes a cloud-only record on its next sync — as a browser
// upload from the extension does.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/settings/secure_store.dart';
import 'package:photos_vault/sync/log_bucket.dart';
import 'package:photos_vault/sync/log_sync.dart';
import 'package:photos_vault/sync/op.dart';
import 'package:photos_vault/sync/sync_store.dart';
import 'package:photos_vault/sync/translate.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Memory implements SecureStore {
  final _m = <String, String>{};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

Map<String, String> _env(String path) => {
  for (final l in File(path).readAsLinesSync())
    if (l.contains('=') && !l.trimLeft().startsWith('#'))
      l.substring(0, l.indexOf('=')).trim(): l
          .substring(l.indexOf('=') + 1)
          .trim()
          .replaceAll(RegExp('^["\']|["\']\$'), ''),
};

void main() {
  setUpAll(sqfliteFfiInit);
  test('publish', () async {
    HttpOverrides.global = null;
    final work = Platform.environment['WORK'] ?? '/tmp/zip-import';
    final b = _env('${Directory.current.path}/.env.bucket');
    final target = await BackupTargetsStore(store: _Memory()).add(
      accessKeyId: b['AWS_ACCESS_KEY_ID']!,
      secretAccessKey: b['AWS_SECRET_ACCESS_KEY']!,
      region: b['AWS_DEFAULT_REGION']!,
      bucket: b['BUCKET']!,
      prefix: b['PREFIX']!,
    );
    final survey = {
      for (final l in File('$work/survey.jsonl').readAsLinesSync())
        if (jsonDecode(l) case final Map<String, dynamic> r
            when r['sha256'] != null)
          r['sha256'] as String: r,
    };
    final dates = {
      for (final l in File('$work/dates.jsonl').readAsLinesSync())
        (jsonDecode(l) as Map)['sha256'] as String:
            (jsonDecode(l) as Map)['taken'] as String,
    };
    final published = File('$work/published.jsonl');
    final done = {
      if (published.existsSync())
        for (final l in published.readAsLinesSync())
          (jsonDecode(l) as Map)['to'] as String,
    };
    final changes = <Change>[];
    final lines = <String>[];
    for (final l in File('$work/renamed.jsonl').readAsLinesSync()) {
      final d = jsonDecode(l) as Map<String, dynamic>;
      final key = d['to'] as String;
      if (done.contains(key)) continue;
      final r = survey[d['sha256']]!;
      final raw = dates[d['sha256']] ?? r['taken'] as String;
      // Camera and name dates are local wall time; a video's is UTC.
      final taken = DateTime.parse(raw);
      final name = key.split('/').last;
      final stem = name.substring(0, name.lastIndexOf('.'));
      final video = r['kind'] == 'video';
      changes.add(
        Change(
          'asset',
          'bucket:$stem',
          OpKind.add,
          x: {
            'created_at': taken.millisecondsSinceEpoch,
            'original_key': key,
            'thumbnail_key': '${b['PREFIX']}/thumbnails/$stem.jpg',
            'content_hash': 'bucket:$stem',
            'original_hash': null,
            'is_video': video ? 1 : 0,
            'is_live_photo': 0,
            'width': r['width'],
            'height': r['height'],
            'latitude': null,
            'longitude': null,
            'description': '',
            'location': null,
            'is_favorite': 0,
            'is_archived': 0,
            'deleted_at': null,
          },
        ),
      );
      lines.add(jsonEncode({'to': key, 'id': 'bucket:$stem'}));
    }
    print('to publish: ${changes.length}');
    if (changes.isEmpty) return;
    final store = SyncStore(
      databaseFactory: databaseFactoryFfi,
      path: '$work/mac-sync.db',
    );
    final sync = LogSync(
      store: store,
      bucket: S3LogBucket(target),
      sources: const [],
      privateAssets: (_) async => const {},
    );
    final limit = int.parse(Platform.environment['LIMIT'] ?? '0');
    final take = limit > 0 ? limit : changes.length;
    await store.addChanges(changes.take(take).toList());
    final sent = await sync.flush();
    print('device ${await store.device()}: $sent segments sent');
    if (await sync.fatal() case final f?) fail('sync stopped: $f');
    published.writeAsStringSync(
      '${lines.take(take).join('\n')}\n',
      mode: FileMode.append,
    );
    await store.close();
  }, timeout: Timeout.none);
}

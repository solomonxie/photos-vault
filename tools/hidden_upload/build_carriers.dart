// ignore_for_file: avoid_print
// Run through `flutter test` (the app's code needs Flutter's libraries);
// see README.md. Reads everything from $PV_WORK, writes carriers there.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photos_vault/photos/file_hash.dart';
import 'package:photos_vault/photos/image_pipeline.dart' show thumbnailMaxEdge;
import 'package:photos_vault/photos/person_store.dart';
import 'package:photos_vault/settings/secure_store.dart';
import 'package:photos_vault/storage/asset_record.dart';
import 'package:photos_vault/storage/asset_record_store.dart';
import 'package:photos_vault/storage/passcode_hash.dart';
import 'package:photos_vault/vault/album_index.dart';
import 'package:photos_vault/vault/carrier.dart';
import 'package:photos_vault/vault/carrier_upload.dart';
import 'package:photos_vault/vault/cipher.dart';
import 'package:photos_vault/vault/decoy.dart';
import 'package:photos_vault/vault/keys.dart';
import 'package:photos_vault/vault/object_key.dart';
import 'package:photos_vault/vault/passcode_tags.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _MemoryStore implements SecureStore {
  final _m = <String, String>{};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

final _work = Platform.environment['PV_WORK']!;
String _at(String name) => p.join(_work, name);

Map<String, List<String>> _vaultEnv() {
  final out = <String, List<String>>{};
  for (final line in File(
    Platform.environment['PV_VAULT_ENV']!,
  ).readAsLinesSync()) {
    final at = line.indexOf('=');
    if (line.trim().startsWith('#') || at < 1) continue;
    var v = line.substring(at + 1).trim();
    if (v.length > 1 && (v[0] == '"' || v[0] == "'") && v.endsWith(v[0])) {
      v = v.substring(1, v.length - 1);
    }
    final k = line.substring(0, at).trim();
    (out[k.startsWith('DIGITS') ? 'DIGITS' : k] ??= []).add(v);
  }
  return out;
}

Future<Uint8List?> _sips(Uint8List bytes, List<String> args) async {
  final dir = await Directory.systemTemp.createTemp('pv_sips_');
  try {
    final input = File(p.join(dir.path, 'in'))..writeAsBytesSync(bytes);
    final out = p.join(dir.path, 'out.jpg');
    final r = await Process.run('sips', [
      ...args,
      '-s',
      'format',
      'jpeg',
      input.path,
      '--out',
      out,
    ]);
    if (r.exitCode != 0 || !File(out).existsSync()) return null;
    return File(out).readAsBytesSync();
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// The hidden photo's own thumbnail: ImageIO by way of `sips`, as the
/// phone's native path does (pure Dart can't read HEIC).
Future<Uint8List?> _thumb(Uint8List bytes) =>
    _sips(bytes, ['-Z', '$thumbnailMaxEdge']);

/// The decoy, drawn at the other photo's full size.
Future<Uint8List?> _upscale(Uint8List thumb, int w, int h) =>
    _sips(thumb, ['-z', '$h', '$w', '-s', 'formatOptions', '$decoyQuality']);

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  setUpAll(sqfliteFfiInit);
  test('hidden carriers', () async {
    final mode = Platform.environment['PV_MODE'] ?? 'check';
    final env = _vaultEnv();
    final records = AssetRecordStore(
      databaseFactory: databaseFactoryFfi,
      path: _at('photos_vault.db'),
    );
    final people = PersonStore(
      databaseFactory: databaseFactoryFfi,
      path: _at('people.db'),
    );
    final keys = VaultKeys(store: _MemoryStore(), derive: deriveOnThisIsolate);

    final known = passphrasesIn(File(_at('index.bin')).readAsBytesSync());
    PassphraseEntry? entry;
    for (final e in known) {
      for (final phrase in env['PASSPHRASE'] ?? const <String>[]) {
        if (await keys.unlockEntry(e, phrase)) entry = e;
      }
    }
    if (entry == null) fail('No passphrase in .env.vault opens the bucket.');
    print('passphrase: ok (entry ${entry.id})');

    final escrows = jsonDecode(
      await records.getAppState(PasscodeTags.escrowState) ?? '[]',
    ) as List;
    final sealKey = (await keys.escrowKey(entry.id))!;
    final tagKeys = [
      for (final e in escrows.cast<Map<String, dynamic>>())
        if (e['e'] == entry.id) ?openEscrow(sealKey, e),
    ];
    print('tag keys: ${tagKeys.length}');

    final ids = {
      for (final p in await people.listAll()) p.id,
      ...await people.allAliasIds(),
    };
    final codeOf = <String, String>{};
    for (final digits in env['DIGITS'] ?? const <String>[]) {
      for (final code in [
        digits,
        for (final id in ids) personAlbumCode(id, digits),
      ]) {
        codeOf[hashPasscode(code)] = code;
        for (final k in tagKeys) {
          codeOf[passcodeTagWith(k, code)] = code;
        }
      }
    }
    final hashes = await records.passcodeHashes();
    final owed = <AssetRecord>[];
    var unknown = 0;
    for (final h in hashes) {
      final mine = [
        for (final r in await records.forPasscodeHash(h))
          if (!r.isDeleted &&
              !r.isFullyBackedUp &&
              !r.isLivePhoto &&
              !r.isVideo &&
              r.sourcePath != null)
            r,
      ];
      if (codeOf.containsKey(h)) {
        owed.addAll(mine);
      } else {
        unknown += mine.length;
      }
    }
    print(
      'folders: ${hashes.length}, opened: ${hashes.where(codeOf.containsKey).length}; '
      'photos owed: ${owed.length}, in folders no code opens: $unknown',
    );
    if (mode == 'check') return;

    final candidates = [
      for (final c
          in jsonDecode(File(_at('decoys.json')).readAsStringSync()) as List)
        DecoyCandidate(
          source: DecoySource(
            id: c['id'] as String,
            sizeBytes: c['size'] as int,
            width: c['width'] as int,
            height: c['height'] as int,
            takenAt: DateTime.fromMillisecondsSinceEpoch(c['taken'] as int),
            isVideo: false,
          ),
          thumbnail: () async => File(c['thumb'] as String).readAsBytes(),
        ),
    ];
    final limit = int.parse(Platform.environment['PV_LIMIT'] ?? '0');
    final plain = Directory(_at('plain'));
    final out = Directory(_at('out'))..createSync(recursive: true);
    final manifest = File(_at('built.jsonl'));
    final done = {
      if (manifest.existsSync())
        for (final l in manifest.readAsLinesSync())
          (jsonDecode(l) as Map)['localId'] as String,
    };
    var builder = CarrierBuilder(
      temporaryDirectory: () => out.createTemp('tmp_'),
      nativeThumbnail: _thumb,
      nativeUpscale: _upscale,
    );
    final todo = [
      for (final r in owed)
        if (!done.contains(r.localId)) r,
    ];
    if (limit > 0 && todo.length > limit) todo.removeRange(limit, todo.length);
    plain.createSync(recursive: true);
    var built = 0;
    var next = 0;
    Future<void> worker() async {
      while (next < todo.length) {
        final r = todo[next++];
        final name = p.basename(r.sourcePath!);
        final file = File(p.join(plain.path, name));
        // One file at a time off the phone, gone again once encrypted.
        final copy = await Process.run('xcrun', [
          'devicectl',
          'device',
          'copy',
          'from',
          '--device',
          Platform.environment['PV_DEVICE']!,
          '--domain-type',
          'appDataContainer',
          '--domain-identifier',
          'com.solomonxie.photosVault',
          '--source',
          'Library/Application Support/$name',
          '--destination',
          file.path,
        ]);
        if (copy.exitCode != 0 || !file.existsSync()) {
          print('not copied: ${r.localId}');
          continue;
        }
        try {
          // Each decoy is worn at most twice per builder: a fresh one now
          // and then, so 15k photos don't run out of faces.
          if (built > 0 && built % 4000 == 0) {
            builder = CarrierBuilder(
              temporaryDirectory: () => out.createTemp('tmp_'),
              nativeThumbnail: _thumb,
              nativeUpscale: _upscale,
            );
          }
          final albumKeys = (await keys.activeAlbumKeys(
            codeOf[r.passcodeHash]!,
          ))!;
          final carrier = await builder.build(
            record: r,
            filePath: file.path,
            keys: albumKeys,
            candidates: candidates,
          );
          final hash = await hashFile(file.path);
          if (carrier == null) {
            print('no decoy for ${r.localId}');
            continue;
          }
          // Opened back here, as the phone will: never sent otherwise.
          final opened = openCarrier(
            cipher: PlatformCipher(),
            keys: albumKeys.carrier,
            payload: payloadOf(carrier.readAsBytesSync())!,
          );
          if (opened == null ||
              !_same(opened.original, file.readAsBytesSync()) ||
              !nameBelongsTo(
                p.basename(carrier.path),
                albumKeys.carrier.macKey,
              )) {
            print('does not open back: ${r.localId}');
            carrier.parent.deleteSync(recursive: true);
            continue;
          }
          final carrierName = p.basename(carrier.path);
          final tmp = carrier.parent;
          carrier.renameSync(p.join(out.path, carrierName));
          tmp.deleteSync(recursive: true);
          manifest.writeAsStringSync(
            '${jsonEncode({'localId': r.localId, 'file': carrierName, 'hash': hash})}\n',
            mode: FileMode.append,
            flush: true,
          );
          built++;
          if (built % 100 == 0) print('built $built of ${todo.length}');
        } finally {
          if (file.existsSync()) file.deleteSync();
        }
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
    print('built $built carriers');
    await records.close();
    await people.close();
  }, timeout: Timeout.none);
}

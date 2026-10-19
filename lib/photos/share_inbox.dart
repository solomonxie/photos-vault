import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../vault/plain_files.dart';
import 'manual_add.dart';

/// What the share extension (`ios/ShareExtension/`) left in the App Group:
/// photos and videos shared from Safari or any other app, waiting to be
/// put in the library or a hidden album. Never via Photos.
///
/// The extension writes one folder per share and `<batch>.json` naming its
/// destination, last; [fileBatches] files those without asking. A hidden
/// batch's code waits in the Keychain until then. Loose files at the top
/// ([pending]) are what [file] offers to put away by asking.
///
/// Plain files, out of the device backup, until taken; each is deleted
/// only once its row exists.
class ShareInbox {
  ShareInbox({
    required this.store,
    ManualAddService? manualAdd,
    PlainFiles? plainFiles,
    Future<String?> Function()? inboxPath,
    Future<String?> Function(String ref)? readCode,
    Future<void> Function(String ref)? forgetCode,
  }) : _manualAdd = manualAdd ?? ManualAddService(store: store),
       _plain = plainFiles ?? PlainFiles(store: store),
       _inboxPath = inboxPath ?? _platformPath,
       _readCode = readCode ?? _platformReadCode,
       _forgetCode = forgetCode ?? _platformForgetCode;

  final AssetRecordStore store;
  final ManualAddService _manualAdd;
  final PlainFiles _plain;
  final Future<String?> Function() _inboxPath;
  final Future<String?> Function(String ref) _readCode;
  final Future<void> Function(String ref) _forgetCode;

  static const _channel = MethodChannel('byo.photos/share_inbox');

  static Future<String?> _platformPath() async {
    try {
      return await _channel.invokeMethod<String>('path');
    } catch (_) {
      // No channel (tests, Android), or not signed for the App Group.
      return null;
    }
  }

  static Future<String?> _platformReadCode(String ref) async {
    try {
      return await _channel.invokeMethod<String>('readCode', {'ref': ref});
    } catch (_) {
      return null;
    }
  }

  static Future<void> _platformForgetCode(String ref) async {
    try {
      await _channel.invokeMethod<void>('forgetCode', {'ref': ref});
    } catch (_) {}
  }

  Future<Directory?> _inbox() async {
    final path = await _inboxPath();
    if (path == null) return null;
    final dir = Directory(path);
    return await dir.exists() ? dir : null;
  }

  /// Loose files waiting to be asked about.
  Future<List<File>> pending() async {
    final dir = await _inbox();
    return dir == null ? const [] : _filesIn(dir);
  }

  /// Complete files only: the extension writes `.part` and renames.
  static Future<List<File>> _filesIn(Directory dir) async => [
    await for (final entry in dir.list())
      if (entry is File &&
          !p.basename(entry.path).startsWith('.') &&
          p.extension(entry.path) != '.part' &&
          p.extension(entry.path) != '.json')
        entry,
  ];

  /// Every batch whose destination was chosen in the share sheet, filed.
  /// A hidden batch whose code can't be read is spilled into the loose
  /// files, so it is asked about instead of lost.
  Future<({List<AssetRecord> library, List<AssetRecord> hidden})> fileBatches({
    required Future<String> Function(String code) tagFor,
  }) async {
    final library = <AssetRecord>[];
    final hidden = <AssetRecord>[];
    final dir = await _inbox();
    if (dir == null) return (library: library, hidden: hidden);
    final manifests = [
      await for (final entry in dir.list())
        if (entry is File && p.extension(entry.path) == '.json') entry,
    ];
    for (final manifest in manifests) {
      final ref = p.basenameWithoutExtension(manifest.path);
      final folder = Directory(p.join(dir.path, ref));
      try {
        final destination =
            (jsonDecode(await manifest.readAsString()) as Map)['destination'];
        final files = await folder.exists()
            ? await _filesIn(folder)
            : const <File>[];
        if (destination == 'hidden') {
          final code = await _readCode(ref);
          if (code == null) {
            for (final f in files) {
              await f.rename(p.join(dir.path, p.basename(f.path)));
            }
          } else {
            hidden.addAll(await _add(files, await tagFor(code)));
          }
        } else {
          library.addAll(await _add(files, null));
        }
        if (await folder.exists() && (await _filesIn(folder)).isNotEmpty) {
          continue;
        }
        if (await folder.exists()) await folder.delete(recursive: true);
        await manifest.delete();
        await _forgetCode(ref);
      } catch (_) {
        // Left for next time.
      }
    }
    return (library: library, hidden: hidden);
  }

  /// Adds every loose file, hidden under [passcodeHash] when given.
  Future<List<AssetRecord>> file({String? passcodeHash}) async =>
      _add(await pending(), passcodeHash);

  /// Born hidden when [passcodeHash] is given — never for a moment an
  /// ordinary row a sync could send plain. A file whose bytes are already
  /// another photo here is left to that photo and dropped from the inbox.
  Future<List<AssetRecord>> _add(List<File> files, String? passcodeHash) async {
    final added = <AssetRecord>[];
    for (final file in files) {
      try {
        final created = await _manualAdd.enqueueFile(
          file.path,
          passcodeHash: passcodeHash,
        );
        if (created.passcodeHash == passcodeHash) {
          if (passcodeHash != null) await _plain.keep(created);
          added.add(created);
        }
        await file.delete();
      } catch (_) {
        // Left in the inbox; offered again next time.
      }
    }
    return added;
  }
}

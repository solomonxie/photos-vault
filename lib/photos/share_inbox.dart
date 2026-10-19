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
/// Plain files, out of the device backup, until [file] takes them; each is
/// deleted only once its row exists.
class ShareInbox {
  ShareInbox({
    required this.store,
    ManualAddService? manualAdd,
    PlainFiles? plainFiles,
    Future<String?> Function()? inboxPath,
  }) : _manualAdd = manualAdd ?? ManualAddService(store: store),
       _plain = plainFiles ?? PlainFiles(store: store),
       _inboxPath = inboxPath ?? _platformPath;

  final AssetRecordStore store;
  final ManualAddService _manualAdd;
  final PlainFiles _plain;
  final Future<String?> Function() _inboxPath;

  static const _channel = MethodChannel('byo.photos/share_inbox');

  static Future<String?> _platformPath() async {
    try {
      return await _channel.invokeMethod<String>('path');
    } catch (_) {
      // No channel (tests, Android), or not signed for the App Group.
      return null;
    }
  }

  /// Complete files only: the extension writes `.part` and renames.
  Future<List<File>> pending() async {
    final path = await _inboxPath();
    if (path == null) return const [];
    final dir = Directory(path);
    if (!await dir.exists()) return const [];
    return [
      await for (final entry in dir.list())
        if (entry is File &&
            !p.basename(entry.path).startsWith('.') &&
            p.extension(entry.path) != '.part')
          entry,
    ];
  }

  /// Adds every waiting file, hidden under [passcodeHash] when given. Born
  /// hidden — never for a moment an ordinary row a sync could send plain.
  /// A file whose bytes are already another photo here is left to that
  /// photo and dropped from the inbox.
  Future<List<AssetRecord>> file({String? passcodeHash}) async {
    final added = <AssetRecord>[];
    for (final file in await pending()) {
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

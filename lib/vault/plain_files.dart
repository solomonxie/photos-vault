import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../photos/photo_library_service.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'store.dart';

/// Where a hidden photo's plain file lives: `vault/plain/`, out of the
/// device backup, under a name that says nothing (`<32 hex>.<ext>`). The
/// name it had is kept on the row (`held_name`) for the way back.
///
/// Every move is a rename (or a copy, when another row shares the file),
/// then the row. A kill between the two is found next time by the name:
/// it is derived from the record's id, so the file is where it would be.
/// Nothing is deleted before the row points at the new place.
class PlainFiles {
  PlainFiles({
    required this.store,
    Future<Directory> Function()? directory,
    BackupExclusion? exclusion,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       _exclusion = exclusion ?? const BackupExclusion();

  final AssetRecordStore store;
  final Future<Directory> Function() _directory;
  final BackupExclusion _exclusion;

  static const dirName = 'plain';

  Future<Directory> dir() async {
    final dir = Directory(
      p.join((await _directory()).path, VaultStore.root, dirName),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    // Once per instance, so a failed call is retried next launch.
    await (_excluded ??= _exclusion.exclude(dir.path));
    return dir;
  }

  Future<bool>? _excluded;

  static String neutralName(String localId, String extension) =>
      '${sha256.convert(utf8.encode('plain:$localId')).toString().substring(0, 32)}'
      '${extension.toLowerCase()}';

  /// Moves [record]'s own files under `vault/plain/`. True when it moved.
  Future<bool> keep(AssetRecord record) async {
    final path = record.sourcePath;
    if (record.passcodeHash == null || path == null) return false;
    final root = (await _directory()).path;
    final plain = (await dir()).path;
    if (p.isWithin(plain, path)) return false;
    // Ours only: a file somewhere else is not this app's to move.
    if (!p.isWithin(root, path) ||
        p.isWithin(p.join(root, VaultStore.root), path)) {
      return false;
    }
    final target = p.join(
      plain,
      neutralName(record.localId, p.extension(path)),
    );
    final source = File(path);
    if (!await source.exists()) {
      // Moved before a kill, row not yet updated.
      if (!await File(target).exists()) return false;
    } else {
      final shared = await store.sourcePathShared(path, record.localId);
      await _place(path, target, copy: shared);
    }
    await _carryMotion(path, target);
    await store.moveSourcePath(
      record.localId,
      target,
      heldName: p.basename(path),
    );
    return true;
  }

  /// Moves an un-hidden record's files back beside the app's other files,
  /// under the name they had. True when it moved.
  Future<bool> release(String localId) async {
    final record = await store.getByLocalId(localId);
    final path = record?.sourcePath;
    if (record == null || record.passcodeHash != null || path == null) {
      return false;
    }
    final plain = (await dir()).path;
    if (!p.isWithin(plain, path)) return false;
    final root = (await _directory()).path;
    final held = await store.heldNameOf(localId);
    final safeId = localId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    var target = p.join(root, held ?? '$safeId${p.extension(path)}');
    if (await File(target).exists() && await File(path).exists()) {
      target = p.join(root, '$safeId-${p.basename(path)}');
    }
    if (await File(path).exists()) {
      await _place(path, target);
    } else if (!await File(target).exists()) {
      return false;
    }
    await _carryMotion(path, target);
    await store.moveSourcePath(localId, target, clearHeld: true);
    return true;
  }

  /// Once a launch: hidden rows whose files are still outside, and
  /// un-hidden ones still inside (an un-hide a kill cut short). Resumable;
  /// a row it can't move is tried again next time.
  Future<int> settleAll() async {
    var moved = 0;
    for (final record in await store.hiddenRecords()) {
      try {
        if (await keep(record)) moved++;
      } catch (_) {}
    }
    final plain = (await dir()).path;
    for (final id in await store.plainIdsUnder(plain)) {
      try {
        if (await release(id)) moved++;
      } catch (_) {}
    }
    return moved;
  }

  /// A Live Photo's `.mov` follows its still.
  static Future<void> _carryMotion(String from, String to) async {
    final motion = PhotoLibraryService.heldLiveVideoPath(from);
    if (await File(motion).exists()) {
      await _place(motion, PhotoLibraryService.heldLiveVideoPath(to));
    }
  }

  /// [from] at [to]: renamed, or copied (through a `.part`) when [copy] or
  /// the rename can't cross. A copy leaves [from] where it is.
  static Future<void> _place(
    String from,
    String to, {
    bool copy = false,
  }) async {
    if (!copy) {
      try {
        await File(from).rename(to);
        return;
      } on FileSystemException {
        // Another volume: copied instead, and the original kept.
      }
    }
    final part = '$to.part';
    await File(from).copy(part);
    await File(part).rename(to);
  }
}

/// Where hidden plain files go, for writers that make one directly.
Future<String> plainPathFor(
  PlainFiles plain,
  AssetRecord record,
  String extension,
) async => p.join(
  (await plain.dir()).path,
  PlainFiles.neutralName(record.localId, extension),
);

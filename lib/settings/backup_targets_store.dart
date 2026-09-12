import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'backup_target.dart';
import 'secure_store.dart';

class BackupTargetsStore {
  BackupTargetsStore({SecureStore? store, Uuid? uuid}) : _store = store ?? const FlutterSecureStore(), _uuid = uuid ?? const Uuid();

  final SecureStore _store;
  final Uuid _uuid;

  static const _key = 'backup_targets_v1';

  Future<List<BackupTarget>> loadAll() async {
    final raw = await _store.read(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((e) => BackupTarget.fromJson(e as Map<String, dynamic>)).toList();
    } on FormatException {
      return const [];
    }
  }

  Future<void> _saveAll(List<BackupTarget> targets) {
    return _store.write(_key, jsonEncode(targets.map((t) => t.toJson()).toList()));
  }

  Future<void> _add(BackupTarget target) async {
    final targets = await loadAll();
    await _saveAll([...targets, target]);
  }

  /// Adds an S3 target, assigning it a fresh id, and persists the updated list.
  Future<S3BackupTarget> addS3({
    required String accessKeyId,
    required String secretAccessKey,
    required String region,
    required String bucket,
    required String prefix,
  }) async {
    final target = S3BackupTarget(
      id: _uuid.v4(),
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      region: region,
      bucket: bucket,
      prefix: prefix,
    );
    await _add(target);
    return target;
  }

  /// Adds a local-folder target, assigning it a fresh id, and persists the
  /// updated list. [bookmarkData] must come from a successful
  /// `checkFolderAccess` call — this store doesn't validate it itself.
  Future<LocalFolderBackupTarget> addLocalFolder({
    required String displayName,
    required String bookmarkData,
    String prefix = '',
  }) async {
    final target = LocalFolderBackupTarget(
      id: _uuid.v4(),
      displayName: displayName,
      bookmarkData: bookmarkData,
      prefix: prefix,
    );
    await _add(target);
    return target;
  }

  /// Replaces a local-folder target's bookmark after a successful re-pick
  /// (see T1.8) — everything else about the target is left as-is.
  Future<void> updateLocalFolderBookmark(String id, String bookmarkData) async {
    final targets = await loadAll();
    await _saveAll([
      for (final t in targets)
        if (t.id == id && t is LocalFolderBackupTarget)
          LocalFolderBackupTarget(id: t.id, displayName: t.displayName, bookmarkData: bookmarkData, prefix: t.prefix)
        else
          t,
    ]);
  }

  Future<void> remove(String id) async {
    final targets = await loadAll();
    await _saveAll(targets.where((t) => t.id != id).toList());
  }
}

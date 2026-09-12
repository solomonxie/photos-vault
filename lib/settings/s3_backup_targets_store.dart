import 'dart:convert';

import 'package:uuid/uuid.dart';

import 's3_backup_target.dart';
import 'secure_store.dart';

class S3BackupTargetsStore {
  S3BackupTargetsStore({SecureStore? store, Uuid? uuid}) : _store = store ?? const FlutterSecureStore(), _uuid = uuid ?? const Uuid();

  final SecureStore _store;
  final Uuid _uuid;

  static const _key = 's3_backup_targets_v1';

  Future<List<S3BackupTarget>> loadAll() async {
    final raw = await _store.read(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded.map((e) => S3BackupTarget.fromJson(e as Map<String, dynamic>)).toList();
    } on FormatException {
      return const [];
    }
  }

  Future<void> _saveAll(List<S3BackupTarget> targets) {
    return _store.write(_key, jsonEncode(targets.map((t) => t.toJson()).toList()));
  }

  /// Adds [target], assigning it a fresh id, and persists the updated list.
  Future<S3BackupTarget> add({
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
    final targets = await loadAll();
    await _saveAll([...targets, target]);
    return target;
  }

  Future<void> remove(String id) async {
    final targets = await loadAll();
    await _saveAll(targets.where((t) => t.id != id).toList());
  }
}

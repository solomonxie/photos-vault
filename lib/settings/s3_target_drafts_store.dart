import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'backup_storage_type.dart';
import 's3_target_draft.dart';
import 'secure_store.dart';

/// Remembers what was typed on recent attempts at adding a target, so
/// a failed or abandoned attempt doesn't mean retyping everything from
/// scratch. Shown as a quick-fill list on the add screen.
class S3TargetDraftsStore {
  S3TargetDraftsStore({
    SecureStore? store,
    Uuid? uuid,
    DateTime Function()? now,
  }) : _store = store ?? const FlutterSecureStore(),
       _uuid = uuid ?? const Uuid(),
       _now = now ?? DateTime.now;

  final SecureStore _store;
  final Uuid _uuid;
  final DateTime Function() _now;

  /// A draft holds a secret key, typos included: only the last few, and
  /// not for long.
  static const keep = 3;
  static const maxAge = Duration(days: 30);

  static const _key = 's3_target_drafts_v1';

  Future<List<S3TargetDraft>> loadAll() async {
    final stored = await _stored();
    final fresh = stored.where((d) => !_expired(d)).toList();
    if (fresh.length < stored.length) {
      try {
        await _saveAll(fresh);
      } catch (_) {
        // Gone from the list either way; the next save drops it.
      }
    }
    return fresh;
  }

  Future<List<S3TargetDraft>> _stored() async {
    final raw = await _store.read(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => S3TargetDraft.fromJson(e as Map<String, dynamic>))
          .toList();
    } on FormatException {
      return const [];
    }
  }

  /// Undated drafts predate aging; they get a date at the next save.
  bool _expired(S3TargetDraft d) =>
      d.savedAt != null && _now().difference(d.savedAt!) > maxAge;

  Future<void> clearAll() => _store.delete(_key);

  Future<void> _saveAll(List<S3TargetDraft> drafts) {
    return _store.write(
      _key,
      jsonEncode(drafts.map((d) => d.toJson()).toList()),
    );
  }

  /// Saves the current attempt as a draft — replaces an existing draft for
  /// the same bucket + access key rather than piling up duplicates.
  Future<void> save({
    required String accessKeyId,
    required String secretAccessKey,
    required String bucket,
    required String prefix,
    String region = '',
    BackupStorageType provider = BackupStorageType.s3,
  }) async {
    final now = _now();
    final drafts = await loadAll();
    final existingIndex = drafts.indexWhere(
      (d) => d.bucket == bucket && d.accessKeyId == accessKeyId,
    );
    final draft = S3TargetDraft(
      id: existingIndex >= 0 ? drafts[existingIndex].id : _uuid.v4(),
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      bucket: bucket,
      prefix: prefix,
      region: region,
      provider: provider,
      savedAt: now,
    );
    final updated = [
      for (final d
          in drafts) // Just older than this one, so the cap never drops it for them.
        d.savedAt == null
            ? d.stamped(now.subtract(const Duration(milliseconds: 1)))
            : d,
    ];
    if (existingIndex >= 0) {
      updated[existingIndex] = draft;
    } else {
      updated.add(draft);
    }
    final newest = ([
      ...updated,
    ]..sort((a, b) => b.savedAt!.compareTo(a.savedAt!))).take(keep).toSet();
    await _saveAll(updated.where(newest.contains).toList());
  }

  Future<void> remove(String id) async {
    final drafts = await loadAll();
    await _saveAll(drafts.where((d) => d.id != id).toList());
  }

  /// Called after a successful add — the draft graduated into a real
  /// target, so it shouldn't also linger in the draft list.
  Future<void> removeMatching({
    required String accessKeyId,
    required String bucket,
  }) async {
    final drafts = await loadAll();
    await _saveAll(
      drafts
          .where((d) => !(d.bucket == bucket && d.accessKeyId == accessKeyId))
          .toList(),
    );
  }
}

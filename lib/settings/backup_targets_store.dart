import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'backup_storage_type.dart';
import 's3_backup_target.dart';
import 'secure_store.dart';

/// How [BackupCoordinator] works through multiple configured targets.
/// Either way every asset ends up on every target — this only changes the
/// order, not the outcome. [fileByFile] (default) mirrors one asset to
/// every target before moving to the next asset. [bucketByBucket] instead
/// finishes every asset against one target before starting the next, so
/// one bucket is fully redundant as early as possible.
enum BackupOrderStrategy { fileByFile, bucketByBucket }

/// What [BackupCoordinator] actually uploads for a photo. [original]
/// (default) sends the file's bytes as-is. [optimized] re-encodes it as
/// WebP first (see `photos/image_pipeline.dart`) to cut upload/storage
/// size, falling back to the original bytes if the re-encode fails.
/// Videos always upload as original either way — no bundled transcoder.
enum BackupFormat { original, optimized }

/// How often [LibraryScreen] retries pending/failed backups on its own,
/// beyond the explicit "Sync Now" button. [manual] (default) never
/// auto-triggers. Checked opportunistically whenever the app comes to the
/// foreground (launch, or returning to the library) — there's no real iOS
/// background-execution hookup (`BGTaskScheduler`) yet, so a frequency set
/// while the app is closed only actually runs the next time it's opened.
enum SyncFrequency { manual, every15Minutes, everyHour, every6Hours, daily }

const _syncIntervals = {
  SyncFrequency.every15Minutes: Duration(minutes: 15),
  SyncFrequency.everyHour: Duration(hours: 1),
  SyncFrequency.every6Hours: Duration(hours: 6),
  SyncFrequency.daily: Duration(days: 1),
};

/// True if [frequency] isn't [SyncFrequency.manual] and enough time has
/// passed since [lastSyncAt] (or a sync has never run at all).
bool isSyncDue({
  required SyncFrequency frequency,
  required DateTime? lastSyncAt,
  required DateTime now,
}) {
  final interval = _syncIntervals[frequency];
  if (interval == null) return false;
  if (lastSyncAt == null) return true;
  return now.difference(lastSyncAt) >= interval;
}

class BackupTargetsStore {
  BackupTargetsStore({SecureStore? store, Uuid? uuid})
    : _store = store ?? const FlutterSecureStore(),
      _uuid = uuid ?? const Uuid();

  final SecureStore _store;
  final Uuid _uuid;

  static const _key = 'backup_targets_v1';
  static const _orderStrategyKey = 'backup_order_strategy_v1';
  static const _formatKey = 'backup_format_v1';

  Future<BackupOrderStrategy> getOrderStrategy() async {
    final raw = await _store.read(_orderStrategyKey);
    return raw == 'bucketByBucket'
        ? BackupOrderStrategy.bucketByBucket
        : BackupOrderStrategy.fileByFile;
  }

  Future<void> setOrderStrategy(BackupOrderStrategy value) =>
      _store.write(_orderStrategyKey, value.name);

  Future<BackupFormat> getBackupFormat() async {
    final raw = await _store.read(_formatKey);
    return raw == 'optimized' ? BackupFormat.optimized : BackupFormat.original;
  }

  Future<void> setBackupFormat(BackupFormat value) =>
      _store.write(_formatKey, value.name);

  static const _syncFrequencyKey = 'backup_sync_frequency_v1';
  static const _lastSyncAtKey = 'backup_last_sync_at_v1';

  Future<SyncFrequency> getSyncFrequency() async {
    final raw = await _store.read(_syncFrequencyKey);
    return SyncFrequency.values.firstWhere(
      (f) => f.name == raw,
      orElse: () => SyncFrequency.manual,
    );
  }

  Future<void> setSyncFrequency(SyncFrequency value) =>
      _store.write(_syncFrequencyKey, value.name);

  Future<DateTime?> getLastSyncAt() async {
    final raw = await _store.read(_lastSyncAtKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  Future<void> setLastSyncAt(DateTime value) =>
      _store.write(_lastSyncAtKey, value.toIso8601String());

  static const _queuePausedKey = 'sync_queue_paused_v1';
  static const _queueConcurrencyKey = 'sync_queue_concurrency_v1';

  Future<bool> getQueuePaused() async =>
      await _store.read(_queuePausedKey) == 'true';

  Future<void> setQueuePaused(bool value) =>
      _store.write(_queuePausedKey, '$value');

  /// How many jobs `SyncQueue` runs at once. Two by default — enough to keep
  /// a link busy while one file is mid-hash, without hammering a phone's
  /// connection.
  Future<int> getQueueConcurrency() async {
    final raw = await _store.read(_queueConcurrencyKey);
    final parsed = raw == null ? null : int.tryParse(raw);
    return (parsed ?? 2).clamp(1, 8);
  }

  Future<void> setQueueConcurrency(int value) =>
      _store.write(_queueConcurrencyKey, '${value.clamp(1, 8)}');

  Future<List<S3BackupTarget>> loadAll() async {
    final raw = await _store.read(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((e) => S3BackupTarget.fromJson(e as Map<String, dynamic>))
          .toList();
    } on FormatException {
      return const [];
    }
  }

  Future<void> _saveAll(List<S3BackupTarget> targets) {
    return _store.write(
      _key,
      jsonEncode(targets.map((t) => t.toJson()).toList()),
    );
  }

  /// Adds a target, assigning it a fresh id, and persists the updated list.
  Future<S3BackupTarget> add({
    required String accessKeyId,
    required String secretAccessKey,
    required String region,
    required String bucket,
    required String prefix,
    BackupStorageType provider = BackupStorageType.s3,
  }) async {
    final target = S3BackupTarget(
      id: _uuid.v4(),
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      region: region,
      bucket: bucket,
      prefix: prefix,
      provider: provider,
    );
    final targets = await loadAll();
    await _saveAll([...targets, target]);
    return target;
  }

  Future<void> remove(String id) async {
    final targets = await loadAll();
    await _saveAll(targets.where((t) => t.id != id).toList());
  }

  /// Every bucket, credential and preference this store owns. Listed here
  /// rather than derived, because the keychain has no way to enumerate
  /// what belongs to one store — a key added later and not added to this
  /// list is a key that survives "remove all app data".
  static const _allKeys = [
    _key,
    _orderStrategyKey,
    _formatKey,
    _syncFrequencyKey,
    _lastSyncAtKey,
    _queuePausedKey,
    _queueConcurrencyKey,
  ];

  Future<void> clearAll() async {
    for (final key in _allKeys) {
      await _store.delete(key);
    }
  }
}

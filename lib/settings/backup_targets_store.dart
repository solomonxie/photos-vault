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

/// What [BackupCoordinator] actually uploads for a photo. [optimized]
/// (default, shown as "HEIF") re-encodes a still as HEIF with iOS's own
/// encoder — full resolution, about half a JPEG — and sends the original
/// whenever that isn't smaller or isn't possible. [original] sends the
/// file's bytes as-is. Videos, Live Photo stills (re-encoding drops the tag
/// that pairs them with their `.mov`) and photos already in HEIF always go
/// as they are.
enum BackupFormat { original, optimized }

/// How often [LibraryScreen] retries pending/failed backups on its own,
/// beyond the explicit "Sync Now" button. [manual] (default) never
/// auto-triggers. Checked opportunistically whenever the app comes to the
/// foreground (launch, or returning to the library), and by an iOS
/// background pass (`upload/background_sync.dart`) when iOS grants one —
/// typically overnight, on power and Wi-Fi, never on a schedule you can
/// count on.
enum SyncFrequency { manual, every15Minutes, everyHour, every6Hours, daily }

/// Backup is always automatic: the queue drains as photos arrive, and a
/// full pass runs when the app comes forward this long after the last.
const autoSyncFrequency = SyncFrequency.every15Minutes;

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
    return raw == 'original' ? BackupFormat.original : BackupFormat.optimized;
  }

  Future<void> setBackupFormat(BackupFormat value) =>
      _store.write(_formatKey, value.name);

  /// Written by builds that offered a choice; read by none. Kept so a
  /// wipe still clears it.
  static const _syncFrequencyKey = 'backup_sync_frequency_v1';
  static const _lastSyncAtKey = 'backup_last_sync_at_v1';

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

  /// Which bucket and folder a target is, whatever its credentials.
  static String identityOf(
    BackupStorageType provider,
    String bucket,
    String prefix,
  ) {
    var folder = prefix.trim();
    while (folder.startsWith('/')) {
      folder = folder.substring(1);
    }
    while (folder.endsWith('/')) {
      folder = folder.substring(0, folder.length - 1);
    }
    return '${provider.name}|${bucket.trim().toLowerCase()}|$folder';
  }

  /// The id a bucket gets every time it is added: derived from where it
  /// is, so removing and re-adding it finds the deletes still owed to it
  /// (and its per-bucket upload rows) rather than leaving them dormant.
  /// Targets added before ids were derived are remembered on removal.
  Future<String> _idFor(String identity) async =>
      (await _rememberedIds())[identity] ??
      _uuid.v5(Namespace.url.value, 'photos-vault:target:$identity');

  /// Names only, no credentials. Outlives Remove All App Data on purpose:
  /// the deletes owed to a bucket do too (`AppDataRemoval`).
  static const _idsKey = 'backup_target_ids_v1';

  Future<Map<String, String>> _rememberedIds() async {
    try {
      final raw = await _store.read(_idsKey);
      if (raw == null || raw.isEmpty) return {};
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  Future<void> _remember(Iterable<S3BackupTarget> targets) async {
    final ids = await _rememberedIds();
    var changed = false;
    for (final t in targets) {
      final identity = identityOf(t.provider, t.bucket, t.prefix);
      if (ids[identity] == t.id) continue;
      ids[identity] = t.id;
      changed = true;
    }
    if (changed) await _store.write(_idsKey, jsonEncode(ids));
  }

  /// Adds a target and persists the updated list. The same bucket and
  /// folder again is not a second target — every upload would go twice to
  /// the same key, and one's superseded-delete would remove what the
  /// other's row still points at — so it replaces that one's credentials
  /// and keeps its id.
  Future<S3BackupTarget> add({
    required String accessKeyId,
    required String secretAccessKey,
    required String region,
    required String bucket,
    required String prefix,
    BackupStorageType provider = BackupStorageType.s3,
  }) async {
    final identity = identityOf(provider, bucket, prefix);
    final targets = await loadAll();
    final same = targets
        .where((t) => identityOf(t.provider, t.bucket, t.prefix) == identity)
        .firstOrNull;
    final target = S3BackupTarget(
      id: same?.id ?? await _idFor(identity),
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      region: region,
      bucket: bucket,
      prefix: prefix,
      provider: provider,
    );
    await _saveAll([
      for (final t in targets) t.id == same?.id ? target : t,
      if (same == null) target,
    ]);
    return target;
  }

  Future<void> remove(String id) async {
    final targets = await loadAll();
    await _remember(targets.where((t) => t.id == id));
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
    try {
      await _remember(await loadAll());
    } catch (_) {
      // Derived ids come back anyway; only an older target's is lost.
    }
    for (final key in _allKeys) {
      await _store.delete(key);
    }
  }
}

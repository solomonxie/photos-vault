import 'dart:async';

import 'package:flutter/foundation.dart';

import '../photos/person_store.dart';
import '../photos/travel_store.dart';
import '../settings/backup_targets_store.dart';
import '../settings/s3_backup_target.dart';
import '../storage/album_store.dart';
import '../storage/asset_record_store.dart';
import 'apply.dart';
import 'bootstrap.dart';
import 'capture.dart';
import 'log_bucket.dart';
import 'log_sync.dart';
import 'merge.dart';
import 'op.dart';
import 'sync_store.dart';
import 'translate.dart';

@immutable
class CloudSyncStatus {
  const CloudSyncStatus({
    this.enabled = false,
    this.homeTargetId,
    this.lastSyncedAt,
    this.waiting = 0,
    this.conflicts = 0,
    this.fatal,
    this.busy = false,
    this.progress,
    this.error,
  });

  final bool enabled;
  final String? homeTargetId;
  final DateTime? lastSyncedAt;
  final int waiting;
  final int conflicts;
  final SyncFatal? fatal;
  final bool busy;

  /// Ops queued so far while the library is first published.
  final int? progress;

  /// The last round's failure, as the bucket or the network put it.
  final String? error;

  /// Something the user should look at: a badge, not a progress line.
  bool get needsAttention => conflicts > 0 || fatal != null;

  CloudSyncStatus copyWith({
    bool? enabled,
    String? homeTargetId,
    DateTime? lastSyncedAt,
    int? waiting,
    int? conflicts,
    SyncFatal? Function()? fatal,
    bool? busy,
    int? Function()? progress,
    String? Function()? error,
  }) => CloudSyncStatus(
    enabled: enabled ?? this.enabled,
    homeTargetId: homeTargetId ?? this.homeTargetId,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    waiting: waiting ?? this.waiting,
    conflicts: conflicts ?? this.conflicts,
    fatal: fatal == null ? this.fatal : fatal(),
    busy: busy ?? this.busy,
    progress: progress == null ? this.progress : progress(),
    error: error == null ? this.error : error(),
  );
}

/// Library sync with the home bucket, as the app sees it: turn on, one
/// round (send, pull, apply), and the status line. The protocol is in
/// [LogSync]; this decides when and to which bucket.
///
/// Off only stops the network. Once a phone has synced, its edits keep
/// being captured, so turning it back on sends what was made meanwhile
/// instead of losing it to the cloud's copy.
class CloudSync {
  CloudSync({
    required this.assets,
    required this.albums,
    required this.people,
    this.travel,
    BackupTargetsStore? targets,
    SyncStore? store,
    LogBucket Function(S3BackupTarget target)? bucketFor,
  }) : targets = targets ?? BackupTargetsStore(),
       store = store ?? SyncStore(),
       _bucketFor = bucketFor ?? S3LogBucket.new;

  final AssetRecordStore assets;
  final AlbumStore albums;
  final PersonStore people;

  /// Places, impressions and plans; null leaves them out of sync.
  final TravelStore? travel;
  final BackupTargetsStore targets;
  final SyncStore store;
  final LogBucket Function(S3BackupTarget) _bucketFor;

  final status = ValueNotifier(const CloudSyncStatus());

  /// The one the open app runs, set by `LibraryScreen`; Settings reads it.
  static CloudSync? instance;

  /// Called after a round changed local rows, for the screens to reload.
  void Function(Applied applied)? onApplied;

  static const pullEvery = Duration(minutes: 2);
  static const checkpointEvery = Duration(days: 7);

  late final _sources = [
    assets.syncDatabase,
    albums.syncDatabase,
    people.syncDatabase,
    ?travel?.syncDatabase,
  ];

  Future<Applier> _applier() async => Applier(
    store: store,
    assets: assets.syncDatabase,
    albums: albums.syncDatabase,
    people: people.syncDatabase,
    travel: travel?.syncDatabase,
    homeTargetId: await store.meta('home_target'),
  );

  LogSync? _sync;
  String? _syncFor;
  bool _running = false;
  DateTime? _lastPull;

  Future<S3BackupTarget?> _home() async {
    final id = await store.meta('home_target');
    if (id == null) return null;
    for (final t in await targets.loadAll()) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<LogSync?> _logSync() async {
    final target = await _home();
    if (target == null) return null;
    if (_syncFor != target.id) {
      _sync = LogSync(
        store: store,
        bucket: _bucketFor(target),
        sources: _sources,
        privateAssets: assets.privateIds,
      );
      _syncFor = target.id;
    }
    return _sync;
  }

  Future<void> _refresh() async {
    final last = await store.meta('last_synced_at');
    status.value = status.value.copyWith(
      enabled: await store.meta('enabled') == 'true',
      homeTargetId: await store.meta('home_target'),
      lastSyncedAt: last == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(int.parse(last)),
      waiting: await store.waiting(),
      conflicts: await store.conflictCount(),
    );
    final sync = await _logSync();
    if (sync != null) {
      final fatal = await sync.fatal();
      status.value = status.value.copyWith(fatal: () => fatal);
    }
  }

  /// Never throws: a store that can't be read leaves the status as it was.
  Future<void> load() async {
    try {
      await _refresh();
    } catch (_) {}
  }

  /// Starts syncing with [target]. First time on this bucket: publishes the
  /// library if the bucket has none, else joins it — the cloud's values for
  /// what both have, this phone's for what only it has.
  Future<void> enable(S3BackupTarget target) async {
    if (_running) return;
    _running = true;
    status.value = status.value.copyWith(busy: true, error: () => null);
    try {
      final current = await store.meta('home_target');
      if (current != null && current != target.id) await store.reset();
      await store.setMeta('home_target', target.id);
      // Capture first: anything written while the library is read is caught
      // twice, which is harmless, rather than not at all.
      for (final open in _sources) {
        await setCapture(await open(), enabled: true);
      }
      final sync = (await _logSync())!;
      if (await store.meta('joined') != 'true') {
        await _join(sync);
        await store.setMeta('joined', true);
      }
      await store.setMeta('enabled', true);
    } catch (e) {
      status.value = status.value.copyWith(error: () => '$e');
    } finally {
      _running = false;
      status.value = status.value.copyWith(busy: false, progress: () => null);
    }
    await _refresh();
    await round();
  }

  Future<void> _join(LogSync sync) async {
    final hasCloud = await sync.newestCheckpoint() != null;
    final cloudKeys = <String>{};
    if (hasCloud) {
      await sync.adoptCheckpoint();
      final keys = await sync.pull();
      await for (final page in store.keyPages()) {
        cloudKeys.addAll(page);
      }
      cloudKeys.addAll(keys);
    }
    await queueLibrary(
      store: store,
      assets: await assets.syncDatabase(),
      albums: await albums.syncDatabase(),
      people: await people.syncDatabase(),
      skip: cloudKeys,
      progress: (n) => status.value = status.value.copyWith(progress: () => n),
    );
    await _queueTravel(skip: cloudKeys);
    // People the cloud had were skipped above: their rows still join.
    await _queueProfiles(
      sync,
      only: {
        for (final k in cloudKeys)
          if (k.startsWith('person/')) k.substring(7),
      },
    );
    if (hasCloud) await _apply(cloudKeys);
    // The rest carry presence in their `add`.
    await queuePresence(store: store, assets: await assets.syncDatabase());
    await store.setMeta('presence_joined', true);
    await sync.flush();
    await sync.publishCheckpoint();
    await store.setMeta(
      'last_checkpoint_at',
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Raised whenever the applier learns to write something new (an entity,
  /// a field). An older build pulled those ops and dropped them on the
  /// floor; they're in the merged state, and are applied once more here.
  static const applierVersion = 2;

  Future<void> _reapplyOnce() async {
    final had = int.tryParse(await store.meta('applier_version') ?? '') ?? 0;
    if (had >= applierVersion) return;
    final keys = <String>{};
    await for (final page in store.keyPages()) {
      keys.addAll(page);
    }
    final applied = await _apply(keys);
    if (applied.deferred.isEmpty) {
      await store.setMeta('applier_version', applierVersion);
    }
  }

  /// Profiles (events, places, groups, details…) joined the log after
  /// people did: a phone that synced before sends its rows once, merged
  /// with what another phone sent, and sealed before anything is applied,
  /// so the cloud's set never removes a row this phone hadn't sent yet.
  /// [only]: just these people (a first sync, which queued the rest).
  Future<void> _queueProfiles(LogSync sync, {Set<String>? only}) async {
    if (await store.meta('profiles_joined') == 'true') return;
    final db = await people.syncDatabase();
    final keys = <String>[];
    await for (final page in store.keyPages()) {
      keys.addAll(page.where((k) => k.startsWith('person/')));
    }
    final cloud = SyncState();
    await store.loadInto(cloud, keys);
    final ids = {for (final k in keys) k.substring(7)};
    await queueProfiles(
      store: store,
      people: db,
      skip: only == null
          ? const {}
          : {
              for (final r in await db.query('person', columns: ['id']))
                if (!only.contains(r['id'])) r['id'] as String,
            },
      cloud: (id) => ids.contains(id) ? cloud.entities['person/$id'] : null,
    );
    await sync.seal();
    await store.setMeta('profiles_joined', true);
  }

  /// Presence (which phones hold a photo) joined the log after the photos
  /// did: a phone sends its own once, sealed first so every photo it has
  /// sent is in the state it compares against.
  Future<void> _queuePresence(LogSync sync) async {
    if (await store.meta('presence_joined') == 'true') return;
    await sync.seal();
    await queuePresence(store: store, assets: await assets.syncDatabase());
    await store.setMeta('presence_joined', true);
  }

  /// Travel joined the log after the photos did: a phone that synced
  /// before sends its travel once, keeping the cloud's values for anything
  /// another phone already sent.
  Future<void> _queueTravel({Set<String>? skip}) async {
    final travel = this.travel;
    if (travel == null || await store.meta('travel_joined') == 'true') return;
    final db = await travel.syncDatabase();
    await setCapture(db, enabled: true);
    final known = skip ?? <String>{};
    if (skip == null) {
      await for (final page in store.keyPages()) {
        known.addAll(
          page.where(
            (k) =>
                k.startsWith('place/') ||
                k.startsWith('entry/') ||
                k.startsWith('route/'),
          ),
        );
      }
    }
    await queueTravel(
      store: store,
      travel: db,
      private: assets.privateIds,
      skip: known,
    );
    await store.setMeta('travel_joined', true);
  }

  /// The open conflicts on one entity: values that lost to a concurrent edit.
  Future<List<Conflict>> conflictsFor(String e, String id) async {
    final s = SyncState();
    await store.loadInto(s, ['$e/$id']);
    return s.conflicts();
  }

  /// Settles [c]'s field on [value]: a fresh edit made after seeing every
  /// value in the conflict, so it supersedes them all everywhere.
  Future<void> resolve(Conflict c, Object? value) async {
    await store.addChanges([Change(c.e, c.id, OpKind.set, f: c.f, x: value)]);
    await _refresh();
    unawaited(round());
  }

  /// Stops the network rounds; edits are still captured for later.
  Future<void> pause() async {
    await store.setMeta('enabled', false);
    await _refresh();
  }

  Future<void> resume() async {
    await store.setMeta('enabled', true);
    await _refresh();
    await round();
  }

  Future<Applied> _apply(Set<String> keys) async {
    final deferredRaw = await store.meta('deferred');
    final all = {
      ...keys,
      if (deferredRaw != null && deferredRaw.isNotEmpty)
        ...deferredRaw.split('\n'),
    };
    final applied = Applied();
    final applier = await _applier();
    Future<void> run(List<String> list) async {
      for (var i = 0; i < list.length; i += 2000) {
        final part = await applier.apply(
          list.sublist(i, (i + 2000).clamp(0, list.length)).toSet(),
        );
        applied.assets += part.assets;
        applied.created += part.created;
        applied.albums += part.albums;
        applied.people += part.people;
        applied.travel += part.travel;
        applied.deferred.addAll(part.deferred);
      }
    }

    await run(all.toList());
    // New records: the albums and people that name them were applied
    // before they existed here, with those members left out.
    if (applied.created > 0) {
      final owners = <String>[];
      await for (final page in store.keyPages()) {
        owners.addAll(
          page.where((k) => k.startsWith('album/') || k.startsWith('person/')),
        );
      }
      await run(owners);
    }
    await store.setMeta('deferred', applied.deferred.join('\n'));
    if (applied.any) onApplied?.call(applied);
    return applied;
  }

  /// One round: send what's waiting, pull, apply. Never throws; a failure
  /// is the status line's error until the next round succeeds.
  Future<void> round() async {
    if (_running) return;
    if (await store.meta('enabled') != 'true') return;
    final sync = await _logSync();
    if (sync == null) return;
    _running = true;
    status.value = status.value.copyWith(busy: true);
    try {
      await sync.flush();
      await _queueProfiles(sync);
      await _queuePresence(sync);
      final keys = await sync.pull();
      _lastPull = DateTime.now();
      await _apply(keys);
      await _reapplyOnce();
      await _queueTravel();
      await sync.flush();
      final lastCheckpoint = int.tryParse(
        await store.meta('last_checkpoint_at') ?? '',
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      if (lastCheckpoint == null ||
          now - lastCheckpoint > checkpointEvery.inMilliseconds) {
        await sync.publishCheckpoint();
        await store.setMeta('last_checkpoint_at', now);
      }
      await store.setMeta('last_synced_at', now);
      status.value = status.value.copyWith(error: () => null);
    } catch (e) {
      status.value = status.value.copyWith(error: () => '$e');
    } finally {
      _running = false;
      status.value = status.value.copyWith(busy: false);
      await _refresh();
    }
  }

  /// From a timer while the app is open: a round when edits are waiting or
  /// the last pull is older than [pullEvery]. Cheap when neither.
  Future<void> tick() async {
    try {
      await _tick();
    } catch (_) {
      // A timer has nobody to tell; the next tick tries again.
    }
  }

  Future<void> _tick() async {
    if (_running || await store.meta('enabled') != 'true') return;
    final last = _lastPull;
    final due = last == null || DateTime.now().difference(last) >= pullEvery;
    if (due) return round();
    for (final open in _sources) {
      final db = await open();
      final n = (await readCaptured(db, limit: 1)).length;
      if (n > 0) return round();
    }
    if (await store.waiting() > 0) return round();
  }
}

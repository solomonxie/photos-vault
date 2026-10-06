import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import 'package:share_plus/share_plus.dart';

import '../backup/app_snapshot.dart';
import '../backup/bucket_backup.dart';
import '../backup/icloud_backup.dart';
import '../backup/icloud_drive.dart';
import '../backup/local_vault.dart';
import '../backup/snapshot_file.dart';
import '../l10n/app_localizations.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/person_store.dart';
import '../storage/album_store.dart';
import '../storage/asset_record_store.dart';
import '../upload/bucket_import.dart';
import '../upload/library_restore.dart';
import '../upload/lost_originals.dart';
import '../upload/original_restore.dart';
import '../upload/sync_job.dart';
import '../upload/sync_queue.dart';
import '../vault/keys.dart';
import 'add_backup_screen.dart';
import 'backup_queue_screen.dart';
import 'backup_targets_store.dart';
import 'bucket_browser_screen.dart';
import 'bucket_endpoint.dart';
import 's3_backup_target.dart';
import 'settings_section.dart';

/// "Cloud Settings": a status card that answers "is my library safe?", then
/// the buckets, the upload settings and the app-data copies, each in its own
/// inset group. The queue is a page of its own ([BackupQueueScreen]), opened
/// from the status card. See `docs/design/uiux/cloud-redesign.md`.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.store,
    this.assetRecordStore,
    this.icloudBackup,
    this.bucketBackup,
    this.vault,
    this.snapshotFile,
    this.syncQueue,
    this.syncEverything,
    this.onOpenAsset,
  });

  /// Feeds the status card and opens the queue page. Absent in tests that
  /// are only about the connections.
  final SyncQueue? syncQueue;

  /// What Back Up Now does; see [BackupQueueScreen].
  final Future<int> Function()? syncEverything;
  final Future<void> Function(String localId)? onOpenAsset;

  final BackupTargetsStore? store;
  final AssetRecordStore? assetRecordStore;

  /// The iCloud copy of everything that isn't a photo. Optional so the
  /// screen still stands alone in tests, which have no platform channel to
  /// answer for the container.
  final ICloudBackup? icloudBackup;

  /// The same copy kept in the user's own bucket. Optional so the screen
  /// still stands alone in tests, which never reach a real bucket.
  final BucketBackup? bucketBackup;

  /// The copy in the app's own container — what the export and restore
  /// pills go through. Optional so tests can hand in one pointed at a
  /// temp folder rather than the real container.
  final LocalVault? vault;

  /// Export to a file, and import one back. Optional so tests can supply a
  /// stand-in picker rather than opening the system one.
  final SnapshotFile? snapshotFile;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late final BackupTargetsStore _store = widget.store ?? BackupTargetsStore();
  late final AssetRecordStore _assetRecordStore =
      widget.assetRecordStore ?? AssetRecordStore();

  /// One reader of the three stores, shared by every destination on this
  /// page. They each used to build their own, which meant three sets of
  /// database handles for one library.
  late final AppSnapshotIo _snapshots = AppSnapshotIo(
    assetRecordStore: _assetRecordStore,
    albumStore: AlbumStore(),
    personStore: PersonStore(),
    aiAnalysisStore: AiAnalysisStore(),
  );

  late final ICloudBackup _icloudBackup =
      widget.icloudBackup ??
      ICloudBackup(settings: _assetRecordStore, snapshots: _snapshots);

  late final BucketBackup _bucketBackup =
      widget.bucketBackup ??
      BucketBackup(
        settings: _assetRecordStore,
        targetsStore: _store,
        snapshots: _snapshots,
      );

  /// The copy in the app's own container. Not a destination on this page —
  /// it dies with the app, and offering it beside two that don't would
  /// promise something it can't keep. It's here because the export and
  /// restore pills both go through it.
  late final LocalVault _vault =
      widget.vault ??
      LocalVault(snapshots: _snapshots, settings: _assetRecordStore);

  late final SnapshotFile _snapshotFile =
      widget.snapshotFile ?? SnapshotFile(snapshots: _snapshots, vault: _vault);

  bool _exporting = false;
  bool _restoring = false;

  ICloudState _icloudState = ICloudState.unsupported;
  bool _icloudEnabled = false;
  DateTime? _icloudLastBackupAt;
  bool _icloudBusy = false;

  bool _bucketDataEnabled = false;
  DateTime? _bucketDataLastBackupAt;
  bool _bucketDataBusy = false;
  bool _importing = false;

  List<S3BackupTarget>? _targets;
  BackupOrderStrategy _orderStrategy = BackupOrderStrategy.fileByFile;
  BackupFormat _format = BackupFormat.optimized;
  SyncFrequency _frequency = SyncFrequency.manual;
  DateTime? _lastSyncAt;
  bool _syncing = false;

  /// Counted once per [_reload], never per build: the library is tens of
  /// thousands of records.
  int _backedUpCount = 0;
  int _trackedCount = 0;
  int _lostCount = 0;

  @override
  void initState() {
    super.initState();
    _reload();
    _reloadICloud();
    _reloadBucketData();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The fix for "iCloud Drive is off" happens over in the Settings app, so
  /// the user leaves and comes back. A row still showing the old state on
  /// their return reads as "it didn't work".
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _reloadICloud();
  }

  ImportOffer _importOffer = ImportOffer.none;

  Future<void> _reloadBucketData() async {
    var enabled = false;
    DateTime? lastBackupAt;
    var offer = ImportOffer.none;
    try {
      offer = await ImportOffer.read(_assetRecordStore);
      enabled = await _bucketBackup.isEnabled();
      lastBackupAt = await _bucketBackup.lastBackupAt();
    } catch (_) {
      // No database to remember the switch in — the row reads as off
      // rather than taking the screen down with it.
    }
    if (!mounted) return;
    setState(() {
      _bucketDataEnabled = enabled;
      _bucketDataLastBackupAt = lastBackupAt;
      _importOffer = offer;
    });
  }

  /// Same bargain as the iCloud switch: turning it on writes the copy
  /// straight away, so the switch itself answers "did that work?".
  Future<void> _toggleBucketData(bool value) async {
    setState(() {
      _bucketDataEnabled = value;
      _bucketDataBusy = value;
    });
    await _bucketBackup.setEnabled(value);
    if (!mounted) return;
    setState(() => _bucketDataBusy = false);
    await _reloadBucketData();
  }

  Future<void> _reloadICloud() async {
    var state = ICloudState.unsupported;
    var enabled = false;
    DateTime? lastBackupAt;
    try {
      state = await _icloudBackup.drive.status();
      enabled = await _icloudBackup.isEnabled();
      if (state == ICloudState.available) {
        lastBackupAt = await _icloudBackup.drive.latestWriteAt();
      }
    } catch (_) {
      // No channel and no database to remember the switch in — which is a
      // build that can't do this at all, and the row stays off the page.
      state = ICloudState.unsupported;
    }
    if (!mounted) return;
    setState(() {
      _icloudState = state;
      _icloudEnabled = enabled;
      _icloudLastBackupAt = lastBackupAt;
    });
  }

  /// Flipping it on copies straight away rather than waiting for the next
  /// change, which could be days off — so "did that work?" is answered by
  /// the switch itself, and there's no Sync Now button beside it papering
  /// over the doubt.
  Future<void> _toggleICloud(bool value) async {
    setState(() {
      _icloudEnabled = value;
      _icloudBusy = value;
    });
    await _icloudBackup.setEnabled(value);
    if (!mounted) return;
    setState(() => _icloudBusy = false);
    await _reloadICloud();
  }

  Future<void> _reload() async {
    List<S3BackupTarget> targets = const [];
    try {
      targets = await _store.loadAll();
    } catch (_) {
      // Secure storage unavailable/unreadable — show defaults rather than
      // spinning forever.
    }
    var order = BackupOrderStrategy.fileByFile;
    try {
      order = await _store.getOrderStrategy();
    } catch (_) {
      // Same secure storage as the targets — fall back to the default.
    }
    var backedUp = 0;
    var tracked = 0;
    var lost = 0;
    try {
      for (final r in await _assetRecordStore.listAll()) {
        if (r.isDeleted) continue;
        tracked++;
        if (r.isFullyBackedUp) backedUp++;
      }
      lost = (await LostOriginals(_assetRecordStore).current()).length;
    } catch (_) {
      // Asset store unavailable (e.g. no platform channel in a test) — the
      // status card just reads zero rather than crashing the screen.
    }
    var format = BackupFormat.optimized;
    var frequency = SyncFrequency.manual;
    DateTime? lastSyncAt;
    try {
      format = await _store.getBackupFormat();
      frequency = await _store.getSyncFrequency();
      lastSyncAt = await _store.getLastSyncAt();
    } catch (_) {
      // Same secure storage — the defaults are a working page.
    }
    if (!mounted) return;
    setState(() {
      _targets = targets;
      _backedUpCount = backedUp;
      _trackedCount = tracked;
      _lostCount = lost;
      _orderStrategy = order;
      _format = format;
      _frequency = frequency;
      _lastSyncAt = lastSyncAt;
    });
  }

  // ---------------------------------------------------------------- buckets

  Future<void> _addBackup() async {
    final added = await Navigator.of(context).push<bool>(
      CupertinoPageRoute(builder: (_) => AddBackupScreen(store: _store)),
    );
    if (added != true) return;
    await _reload();
    // The new bucket has no app-data in it at all, and until it does it
    // holds photos under keys that mean nothing without this phone. Waiting
    // for the daily gate would leave it that way until tomorrow.
    if (await _bucketBackup.isEnabled()) {
      unawaited(_bucketBackup.backUpNow());
    }
    if (mounted) await _reloadBucketData();
  }

  void _browse(S3BackupTarget target) {
    // Rooted at the target's own prefix, and can't be navigated above it:
    // that prefix *is* this connection, so everything outside it belongs to
    // whatever else shares the bucket.
    Navigator.of(context)
        .push(
          CupertinoPageRoute(
            builder: (_) => BucketBrowserScreen(
              target: target,
              onDeleteConnection: () => _delete(target),
            ),
          ),
        )
        .then((_) {
          if (mounted) _reload();
        });
  }

  /// The connection's own screen confirms before calling this — a second
  /// dialog here would be asking twice.
  Future<void> _delete(S3BackupTarget target) async {
    await _store.remove(target.id);
    await _reload();
  }

  String _orderLabel(AppLocalizations l10n, BackupOrderStrategy s) =>
      switch (s) {
        BackupOrderStrategy.fileByFile => l10n.settingsBucketOrderFileByFile,
        BackupOrderStrategy.bucketByBucket =>
          l10n.settingsBucketOrderBucketByBucket,
      };

  /// Only ever offered with a second bucket on the page: with one, both
  /// answers are the same upload in the same order, and the menu would be
  /// asking a question that has no consequence.
  ///
  /// Same drop-down as the queue's own settings, for the same reason —
  /// two choices, each needing a sentence, is a sheet's worth of content
  /// rather than a pair of radio rows standing on this page.
  Future<void> _pickOrderStrategy() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showCupertinoModalPopup<BackupOrderStrategy>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.settingsBucketOrderHeading),
        // Leads with what doesn't change: nobody picking an order should
        // come away thinking one of these drops a copy.
        message: Text(
          '${l10n.settingsBucketOrderHint}\n\n'
          '${l10n.settingsBucketOrderFileByFile}: '
          '${l10n.settingsBucketOrderFileByFileDescription}\n\n'
          '${l10n.settingsBucketOrderBucketByBucket}: '
          '${l10n.settingsBucketOrderBucketByBucketDescription}',
        ),
        actions: [
          for (final s in BackupOrderStrategy.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetContext).pop(s),
              child: Text(
                s == _orderStrategy
                    ? '${_orderLabel(l10n, s)}  ✓'
                    : _orderLabel(l10n, s),
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _orderStrategy = picked);
    await _store.setOrderStrategy(picked);
  }

  String _targetPath(S3BackupTarget target) =>
      '${bucketUriScheme(target.provider)}://${target.bucket}/${target.prefix}';

  // ------------------------------------------------------------------ build

  String _frequencyLabel(AppLocalizations l10n, SyncFrequency f) => switch (f) {
    SyncFrequency.manual => l10n.settingsSyncFrequencyManual,
    SyncFrequency.every15Minutes => l10n.settingsSyncFrequencyEvery15Minutes,
    SyncFrequency.everyHour => l10n.settingsSyncFrequencyEveryHour,
    SyncFrequency.every6Hours => l10n.settingsSyncFrequencyEvery6Hours,
    SyncFrequency.daily => l10n.settingsSyncFrequencyDaily,
  };

  String _formatLabel(AppLocalizations l10n, BackupFormat f) => switch (f) {
    BackupFormat.original => l10n.settingsBackupFormatOriginal,
    BackupFormat.optimized => l10n.settingsBackupFormatOptimized,
  };

  Future<void> _pickFrequency() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showCupertinoModalPopup<SyncFrequency>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.settingsSyncFrequencyHeading),
        message: Text(l10n.settingsSyncFrequencyHint),
        actions: [
          for (final f in SyncFrequency.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetContext).pop(f),
              child: Text(
                f == _frequency
                    ? '${_frequencyLabel(l10n, f)}  ✓'
                    : _frequencyLabel(l10n, f),
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _frequency = picked);
    await _store.setSyncFrequency(picked);
  }

  /// Two choices and a sentence about each is a sheet's worth of content,
  /// not half a page of radio rows under a setting changed once.
  Future<void> _pickFormat() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showCupertinoModalPopup<BackupFormat>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.settingsBackupFormatHeading),
        message: Text(
          '${l10n.settingsBackupFormatOriginal}: '
          '${l10n.settingsBackupFormatOriginalDescription}\n\n'
          '${l10n.settingsBackupFormatOptimized}: '
          '${l10n.settingsBackupFormatOptimizedDescription}\n\n'
          '${l10n.settingsBackupFormatVideoNote}\n'
          '${l10n.settingsBackupFormatFolderNote}',
        ),
        actions: [
          for (final f in BackupFormat.values)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(sheetContext).pop(f),
              child: Text(
                f == _format
                    ? '${_formatLabel(l10n, f)}  ✓'
                    : _formatLabel(l10n, f),
              ),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(sheetContext).pop(),
          child: Text(l10n.actionCancel),
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _format = picked);
    await _store.setBackupFormat(picked);
  }

  Future<void> _syncNow() async {
    final syncEverything = widget.syncEverything;
    if (syncEverything == null || _syncing) return;
    setState(() => _syncing = true);
    try {
      await syncEverything();
      await _store.setLastSyncAt(DateTime.now());
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    await _reload();
    await widget.syncQueue?.refresh();
  }

  void _openQueue() {
    final queue = widget.syncQueue;
    if (queue == null) return;
    Navigator.of(context).push(
      CupertinoPageRoute(
        builder: (_) => BackupQueueScreen(
          queue: queue,
          settingsStore: _store,
          syncEverything: widget.syncEverything,
          onOpenAsset: widget.onOpenAsset,
        ),
      ),
    );
  }

  Future<void> _explainAppData() {
    final l10n = AppLocalizations.of(context)!;
    return showCupertinoDialog<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.settingsAppDataHeading),
        content: Text(l10n.settingsAppDataHint),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.actionOk),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final targets = _targets;
    return CupertinoPageScaffold(
      backgroundColor: settingsPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: settingsPageBackground,
        border: null,
        middle: Text(l10n.collectionsCloudSettingsRow),
      ),
      child: targets == null
          ? const Center(child: CupertinoActivityIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.only(top: 8, bottom: 40),
                children: [
                  _statusCard(l10n, targets),
                  const SizedBox(height: 28),
                  SettingsGroupHeading(title: l10n.settingsCloudBucketsHeading),
                  _bucketsGroup(l10n, targets),
                  const SizedBox(height: 28),
                  SettingsGroupHeading(title: l10n.cloudUploadsHeading),
                  _uploadsGroup(l10n, targets),
                  const SizedBox(height: 28),
                  SettingsGroupHeading(
                    title: l10n.settingsAppDataHeading,
                    onInfo: _explainAppData,
                  ),
                  _appDataGroup(l10n, targets),
                ],
              ),
            ),
    );
  }

  // ------------------------------------------------------------ status card

  /// Answers "am I safe?" before anything else on the page. When several
  /// things are true the worst one wins: lost > failed > paused > syncing >
  /// waiting > all done.
  Widget _statusCard(AppLocalizations l10n, List<S3BackupTarget> targets) {
    if (targets.isEmpty) {
      return SettingsStatusCard(
        color: settingsTertiary,
        title: l10n.cloudStatusNone,
        subtitle: l10n.settingsEmptyNote,
      );
    }
    final queue = widget.syncQueue;
    if (queue == null) return _statusFor(l10n, targets, 0, 0, false, false);
    return ValueListenableBuilder<List<SyncJob>>(
      valueListenable: queue.jobs,
      builder: (context, jobs, _) => ValueListenableBuilder<bool>(
        valueListenable: queue.paused,
        builder: (context, paused, _) => ValueListenableBuilder<bool>(
          valueListenable: queue.draining,
          builder: (context, draining, _) {
            var waiting = 0;
            var failed = 0;
            for (final job in jobs) {
              switch (job.status) {
                case SyncJobStatus.pending || SyncJobStatus.running:
                  waiting++;
                case SyncJobStatus.failed:
                  failed++;
                case SyncJobStatus.done:
                  break;
              }
            }
            return _statusFor(l10n, targets, waiting, failed, paused, draining);
          },
        ),
      ),
    );
  }

  Widget _statusFor(
    AppLocalizations l10n,
    List<S3BackupTarget> targets,
    int waiting,
    int failed,
    bool paused,
    bool draining,
  ) {
    final syncing = _syncing || (draining && !paused);
    final lastSync = _lastSyncAt == null
        ? l10n.settingsLastSyncedNever
        : l10n.settingsLastSyncedAt(_formatWhen(_lastSyncAt!));
    final canSync = widget.syncEverything != null && !_syncing;
    final String title;
    final Color color;
    if (_lostCount > 0) {
      title = l10n.cloudStatusLost(_lostCount);
      color = CupertinoColors.systemRed;
    } else if (failed > 0) {
      title = l10n.cloudStatusFailed(failed);
      color = CupertinoColors.systemOrange;
    } else if (paused) {
      title = l10n.cloudStatusPaused(waiting);
      color = CupertinoColors.systemOrange;
    } else if (syncing) {
      title = l10n.cloudStatusSyncing(waiting);
      color = settingsAccent;
    } else if (waiting > 0) {
      title = l10n.cloudStatusWaiting(waiting);
      color = settingsAccent;
    } else {
      title = l10n.cloudStatusAllDone;
      color = CupertinoColors.systemGreen;
    }
    final unfinished = waiting + failed;
    return SettingsStatusCard(
      color: color,
      busy: syncing && _lostCount == 0 && failed == 0,
      title: title,
      subtitle: l10n.cloudStatusProgress(
        _backedUpCount,
        _trackedCount,
        targets.length,
      ),
      progress: _trackedCount == 0 ? null : _backedUpCount / _trackedCount,
      footnote: lastSync,
      primaryLabel: paused
          ? l10n.backupQueueResumeAction
          : _syncing
          ? l10n.settingsSyncingMessage
          : l10n.settingsSyncNowButton,
      onPrimary: paused
          ? () => widget.syncQueue?.setPaused(false)
          : canSync
          ? _syncNow
          : null,
      linkLabel: widget.syncQueue == null
          ? null
          : l10n.cloudQueueLink(unfinished),
      onLink: widget.syncQueue == null ? null : _openQueue,
    );
  }

  // ----------------------------------------------------------------- groups

  Widget _bucketsGroup(AppLocalizations l10n, List<S3BackupTarget> targets) =>
      SettingsGroup(
        children: [
          for (final target in targets)
            SettingsGroupRow(
              leading: const SettingsIconTile(icon: CupertinoIcons.cloud_fill),
              title: target.bucket,
              subtitle: _targetPath(target),
              value: target.region,
              chevron: true,
              onTap: () => _browse(target),
            ),
          SettingsGroupRow(
            title: l10n.settingsAddButton,
            accent: true,
            leading: const Icon(
              CupertinoIcons.add_circled,
              size: 22,
              color: settingsAccent,
            ),
            onTap: _addBackup,
          ),
        ],
      );

  Widget _uploadsGroup(AppLocalizations l10n, List<S3BackupTarget> targets) =>
      SettingsGroup(
        children: [
          SettingsGroupRow(
            title: l10n.cloudSyncRow,
            value: _frequencyLabel(l10n, _frequency),
            chevron: true,
            onTap: _pickFrequency,
          ),
          SettingsGroupRow(
            title: l10n.cloudQualityRow,
            value: _formatLabel(l10n, _format),
            chevron: true,
            onTap: _pickFormat,
          ),
          // With one bucket both orders are the same upload in the same
          // order: a row for a choice that changes nothing is clutter.
          if (targets.length > 1)
            SettingsGroupRow(
              title: l10n.cloudFillOrderRow,
              value: _orderLabel(l10n, _orderStrategy),
              chevron: true,
              onTap: _pickOrderStrategy,
            ),
          if (targets.isNotEmpty)
            ValueListenableBuilder<({int done, int total})?>(
              valueListenable: BucketImport.running,
              builder: (context, running, _) => SettingsGroupRow(
                title: l10n.cloudFindNewRow,
                subtitle: running == null
                    ? null
                    : l10n.cloudFindNewRunning(running.done, running.total),
                value: running == null && _importOffer.importable > 0
                    ? l10n.cloudFindNewValue(_importOffer.importable)
                    : null,
                trailing: running != null || _importing
                    ? const CupertinoActivityIndicator(radius: 9)
                    : null,
                chevron: running == null,
                onTap: running != null || _importing ? null : _importFromBucket,
              ),
            ),
        ],
      );

  /// One switch per destination and nothing else. "Back up here" and "do
  /// it automatically" as separate toggles is three controls for one
  /// decision and nobody can predict what any combination does.
  ///
  /// A container that can't work *right now* still shows its row: hiding it
  /// makes the feature invisible to exactly the person who needs telling
  /// about it. What changes is the line under the title — and only the one
  /// state the user can actually fix gets told how.
  Widget _appDataGroup(AppLocalizations l10n, List<S3BackupTarget> targets) {
    final blocked = switch (_icloudState) {
      ICloudState.notEntitled => l10n.settingsICloudNotEntitled,
      ICloudState.driveOff => l10n.settingsICloudDriveOff,
      ICloudState.notReady => l10n.settingsICloudNotReady,
      ICloudState.available || ICloudState.unsupported => null,
    };
    final iCloudAt = _icloudLastBackupAt;
    final bucketAt = _bucketDataLastBackupAt;
    return SettingsGroup(
      footer: l10n.cloudLocalCopiesFooter,
      children: [
        if (_icloudState != ICloudState.unsupported)
          SettingsGroupRow(
            title: l10n.settingsICloudRow,
            subtitle:
                blocked ??
                (iCloudAt == null
                    ? l10n.settingsICloudNever
                    : l10n.settingsICloudLastBackup(_formatWhen(iCloudAt))),
            trailing: _icloudBusy
                ? const CupertinoActivityIndicator(radius: 9)
                : CupertinoSwitch(
                    value: _icloudEnabled,
                    onChanged: _icloudState == ICloudState.available
                        ? _toggleICloud
                        : null,
                  ),
          ),
        if (_icloudState == ICloudState.driveOff) const _FixLine(),
        SettingsGroupRow(
          title: l10n.settingsBucketDataRow,
          // Nothing to back up to says so where the switch is, rather than
          // letting a dead toggle explain itself.
          subtitle: targets.isEmpty
              ? l10n.settingsBucketDataNoBucket
              : bucketAt == null
              ? l10n.settingsICloudNever
              : l10n.settingsICloudLastBackup(_formatWhen(bucketAt)),
          trailing: _bucketDataBusy
              ? const CupertinoActivityIndicator(radius: 9)
              : CupertinoSwitch(
                  value: _bucketDataEnabled,
                  onChanged: targets.isEmpty ? null : _toggleBucketData,
                ),
        ),
        SettingsGroupRow(
          title: l10n.settingsAppDataExportButton,
          trailing: Icon(
            CupertinoIcons.square_arrow_up,
            size: 20,
            color: _exporting ? settingsTertiary : settingsAccent,
          ),
          onTap: _exporting ? null : _exportFile,
        ),
        SettingsGroupRow(
          title: l10n.settingsAppDataRestoreButton,
          trailing: Icon(
            CupertinoIcons.square_arrow_down,
            size: 20,
            color: _restoring ? settingsTertiary : settingsAccent,
          ),
          onTap: _restoring ? null : _restoreFile,
        ),
      ],
    );
  }

  String _formatWhen(DateTime at) =>
      DateFormat.yMMMd().add_jm().format(at.toLocal());

  // -------------------------------------------------------- file in / out

  /// Hands the payload to the share sheet — AirDrop, Files, Mail, whatever
  /// the user keeps things in. The automatic tiers all answer "I lost my
  /// phone"; none of them answers "I want the file".
  Future<void> _exportFile() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final file = await _snapshotFile.export();
      if (!mounted) return;
      if (file == null) {
        await _tell(AppLocalizations.of(context)!.settingsAppDataExportFailed);
        return;
      }
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Pick, confirm, merge. The confirmation is here rather than inside
  /// [SnapshotFile] because it belongs at the point of action, in the
  /// user's language, restating what the thing about to happen does.
  Future<void> _restoreFile() async {
    if (_restoring) return;
    setState(() => _restoring = true);
    try {
      final snapshot = await _snapshotFile.pick();
      if (!mounted || snapshot == null) return;
      final l10n = AppLocalizations.of(context)!;
      if (snapshot.isEmpty) {
        await _tell(l10n.settingsAppDataRestoreUnreadable);
        return;
      }
      if (!await _confirmRestore(snapshot)) return;
      final restored = await _snapshotFile.restore(snapshot);
      if (!mounted) return;
      // Says what didn't land as well as what did. A file whose photos
      // aren't on this phone yet still restores their captions and tags —
      // the records are there, waiting for a sync to match them up — and
      // reporting only the matches would read as a half-failed import.
      await _tell(
        restored == snapshot.assets.length
            ? l10n.settingsAppDataRestoreDone(restored)
            : l10n.settingsAppDataRestorePartial(
                restored,
                snapshot.assets.length - restored,
              ),
      );
      await _reload();
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  Future<bool> _confirmRestore(AppSnapshot snapshot) async {
    final l10n = AppLocalizations.of(context)!;
    final answer = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.settingsAppDataRestoreConfirmTitle),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // What is in it, before what it will do. Two copies a week apart
            // are indistinguishable otherwise, and "which of these holds
            // more of my library" is the only question anybody has here.
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 8),
              child: Text(
                _summaryLine(l10n, snapshot.summary),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              l10n.settingsAppDataRestoreConfirmBody(
                DateFormat.yMMMd().format(snapshot.exportedAt.toLocal()),
              ),
            ),
          ],
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.settingsAppDataRestoreConfirmAction),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  static String _summaryLine(AppLocalizations l10n, SnapshotSummary summary) =>
      [
        l10n.settingsAppDataRestoreSummaryPhotos(summary.photos),
        l10n.settingsAppDataRestoreSummaryPeople(summary.people),
        l10n.settingsAppDataRestoreSummaryAlbums(summary.albums),
      ].join(' \u00b7 ');

  /// A plain `ls` of the buckets and a diff against what the library
  /// knows, then a question. Nothing is fetched object by object until the
  /// user says import, and then only for the files found.
  Future<void> _importFromBucket() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _importing = true);
    String? message;
    try {
      final import = BucketImport(
        targetsStore: _store,
        recordStore: _assetRecordStore,
        passphrases: VaultKeys().entries,
      );
      final offer = await import.scan(refresh: true);
      if (!mounted) return;
      if (offer.importable == 0) {
        message = [
          l10n.settingsBucketImportDone(0),
          if (offer.duplicates > 0)
            l10n.settingsBucketImportDuplicates(offer.duplicates),
        ].join('\n');
      } else if (await _confirmImport(offer.importable)) {
        final result = await import.run(relist: false);
        if (result.imported > 0) {
          // Not awaited: tiles fill in behind the result, and only the
          // files just imported are fetched, not the whole library.
          unawaited(
            LibraryRestore(
              recordStore: _assetRecordStore,
              originals: OriginalRestore(
                targetsStore: _store,
                recordStore: _assetRecordStore,
              ),
            ).run(only: result.importedIds.toSet()),
          );
        }
        message = [
          l10n.settingsBucketImportDone(result.imported),
          if (result.duplicates > 0)
            l10n.settingsBucketImportDuplicates(result.duplicates),
        ].join('\n');
      }
    } catch (_) {
      message = l10n.settingsBucketImportUnreachable;
    }
    if (!mounted) return;
    setState(() => _importing = false);
    if (message != null) await _tell(message);
    await _reload();
  }

  Future<bool> _confirmImport(int count) async {
    final l10n = AppLocalizations.of(context)!;
    return await showCupertinoDialog<bool>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: Text(l10n.cloudFindNewValue(count)),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(l10n.actionCancel),
              ),
              CupertinoDialogAction(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(l10n.flaggedImport),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _tell(String message) => showCupertinoDialog<void>(
    context: context,
    builder: (dialogContext) => CupertinoAlertDialog(
      content: Text(message),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(AppLocalizations.of(context)!.actionOk),
        ),
      ],
    ),
  );
}

/// The one fix the user can make themselves, in the accent colour, under
/// the iCloud row it belongs to.
class _FixLine extends StatelessWidget {
  const _FixLine();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      settingsPagePadding,
      0,
      settingsPagePadding,
      10,
    ),
    child: Text(
      AppLocalizations.of(context)!.settingsICloudDriveOffFix,
      style: const TextStyle(fontSize: 12, color: settingsAccent),
    ),
  );
}

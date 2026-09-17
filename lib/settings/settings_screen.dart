import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:intl/intl.dart';

import '../backup/app_snapshot.dart';
import '../backup/icloud_backup.dart';
import '../backup/icloud_drive.dart';
import '../l10n/app_localizations.dart';
import '../photos/person_store.dart';
import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/backup_coordinator.dart';
import '../upload/sync_job.dart';
import '../upload/sync_queue.dart';
import '../viewer/sync_queue_sheet.dart';
import 'add_s3_backup_screen.dart';
import 'backup_targets_store.dart';
import 'bucket_browser_screen.dart';
import 's3_backup_target.dart';
import 'settings_section.dart';

/// "Cloud Settings" — one flat page: the bucket list up top, then the
/// settings that govern syncing it. Nothing here pushes a sub-page that
/// only holds controls; per-connection actions live in that row's own `…`
/// sheet, and the queue opens as a sheet over this page rather than a
/// destination of its own.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.store,
    this.assetRecordStore,
    this.retryRecords,
    this.syncEverything,
    this.syncQueue,
    this.openAsset,
    this.icloudBackup,
  });

  final BackupTargetsStore? store;
  final AssetRecordStore? assetRecordStore;

  /// Re-attempts exactly the records given, no local-change check.
  /// Defaults to a plain [BackupCoordinator] run for standalone/test use;
  /// `LibraryScreen` always passes its own so a retry here shares the same
  /// in-flight-run bookkeeping.
  final Future<int> Function(List<AssetRecord> records)? retryRecords;

  /// Backs "Sync Now" — checks every already-uploaded asset for a local
  /// edit first, then backs up everything pending/failed. Defaults to
  /// [retryRecords] over pending/failed only (no change-detection) for
  /// standalone/test use.
  final Future<int> Function()? syncEverything;

  /// The live sync queue, for the status line and its sheet. Optional so
  /// the screen still stands alone in tests; without one the status line
  /// just reads as idle.
  final SyncQueue? syncQueue;

  /// The iCloud copy of everything that isn't a photo. Optional so the
  /// screen still stands alone in tests, which have no platform channel to
  /// answer for the container.
  final ICloudBackup? icloudBackup;

  /// Opens one asset in the photo viewer — what tapping a queue row does.
  /// Owned by `LibraryScreen`, which is where the viewer and the records
  /// live. Absent, queue rows aren't tappable.
  final Future<void> Function(String localId)? openAsset;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  late final BackupTargetsStore _store = widget.store ?? BackupTargetsStore();
  late final AssetRecordStore _assetRecordStore =
      widget.assetRecordStore ?? AssetRecordStore();
  late final Future<int> Function(List<AssetRecord> records) _retryRecords =
      widget.retryRecords ??
      (records) =>
          BackupCoordinator(
            targetsStore: _store,
            recordStore: _assetRecordStore,
          ).backUpBatch(
            records: records,
            kind: DerivativeKind.original,
            resolvePath: (r) async => r.sourcePath,
          );
  late final Future<int> Function() _syncEverything =
      widget.syncEverything ??
      () async {
        final all = await _assetRecordStore.listAll();
        final due = all.where((r) {
          if (r.isDeleted) return false;
          final status = r.stateOf(DerivativeKind.original).status;
          return status == UploadStatus.pending ||
              status == UploadStatus.failed;
        }).toList();
        return _retryRecords(due);
      };

  late final ICloudBackup _icloudBackup =
      widget.icloudBackup ??
      ICloudBackup(
        settings: _assetRecordStore,
        snapshots: AppSnapshotIo(
          assetRecordStore: _assetRecordStore,
          albumStore: AlbumStore(),
          personStore: PersonStore(),
        ),
      );

  ICloudState _icloudState = ICloudState.unsupported;
  bool _icloudEnabled = false;
  DateTime? _icloudLastBackupAt;
  bool _icloudBusy = false;

  List<S3BackupTarget>? _targets;
  List<AssetRecord> _records = const [];
  BackupFormat _format = BackupFormat.original;
  SyncFrequency _frequency = SyncFrequency.manual;
  DateTime? _lastSyncAt;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _reload();
    _reloadICloud();
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
    var format = BackupFormat.original;
    var frequency = SyncFrequency.manual;
    DateTime? lastSyncAt;
    try {
      targets = await _store.loadAll();
      format = await _store.getBackupFormat();
      frequency = await _store.getSyncFrequency();
      lastSyncAt = await _store.getLastSyncAt();
    } catch (_) {
      // Secure storage unavailable/unreadable — show defaults rather than
      // spinning forever.
    }
    List<AssetRecord> records = const [];
    try {
      records = await _assetRecordStore.listAll();
    } catch (_) {
      // Asset store unavailable (e.g. no platform channel in a test) — the
      // stats line just reads zero rather than crashing the screen.
    }
    if (!mounted) return;
    setState(() {
      _targets = targets;
      _records = records;
      _format = format;
      _frequency = frequency;
      _lastSyncAt = lastSyncAt;
    });
  }

  // ---------------------------------------------------------------- buckets

  Future<void> _addBackup() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AddS3BackupScreen(store: _store)),
    );
    if (added == true) await _reload();
  }

  void _browse(S3BackupTarget target) {
    // Rooted at the target's own prefix, and can't be navigated above it:
    // that prefix *is* this connection, so everything outside it belongs to
    // whatever else shares the bucket.
    Navigator.of(context)
        .push(
          MaterialPageRoute(
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

  String _targetPath(S3BackupTarget target) =>
      's3://${target.bucket}/${target.prefix}';

  // ------------------------------------------------------------------- sync

  String _frequencyLabel(AppLocalizations l10n, SyncFrequency f) => switch (f) {
    SyncFrequency.manual => l10n.settingsSyncFrequencyManual,
    SyncFrequency.every15Minutes => l10n.settingsSyncFrequencyEvery15Minutes,
    SyncFrequency.everyHour => l10n.settingsSyncFrequencyEveryHour,
    SyncFrequency.every6Hours => l10n.settingsSyncFrequencyEvery6Hours,
    SyncFrequency.daily => l10n.settingsSyncFrequencyDaily,
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

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await _syncEverything();
      await _store.setLastSyncAt(DateTime.now());
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    await _reload();
  }

  /// How many uploads run at once, as a stepper rather than a menu: it's a
  /// number you nudge and watch, not a value you pick from a list.
  Widget _paceButtons(AppLocalizations l10n) {
    final queue = widget.syncQueue!;
    return ValueListenableBuilder<int>(
      valueListenable: queue.concurrency,
      builder: (context, concurrency, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsPillButton(
            icon: CupertinoIcons.minus,
            label: l10n.backupQueueSlowerShort,
            onPressed: concurrency <= 1
                ? null
                : () => queue.setConcurrency(concurrency - 1),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              l10n.backupQueueSpeed(concurrency),
              style: settingsRowSubtitleStyle,
            ),
          ),
          SettingsPillButton(
            icon: CupertinoIcons.plus,
            label: l10n.backupQueueFasterShort,
            onPressed: () => queue.setConcurrency(concurrency + 1),
          ),
        ],
      ),
    );
  }

  String _formatLabel(AppLocalizations l10n, BackupFormat f) => switch (f) {
    BackupFormat.original => l10n.settingsBackupFormatOriginal,
    BackupFormat.optimized => l10n.settingsBackupFormatOptimized,
  };

  /// The same drop-down the sync frequency uses, for the same reason: two
  /// choices and a sentence about each is a sheet's worth of content, not
  /// half a page of permanently-visible radio rows under a setting that
  /// gets changed once.
  Future<void> _pickFormat() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showCupertinoModalPopup<BackupFormat>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: Text(l10n.settingsBackupFormatHeading),
        // What each one costs you, where the choice is actually made.
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
    await _setFormat(picked);
  }

  Future<void> _setFormat(BackupFormat value) async {
    setState(() => _format = value);
    await _store.setBackupFormat(value);
  }

  Future<void> _openQueue() async {
    final queue = widget.syncQueue;
    if (queue == null) return;
    await showSyncQueueSheet(context, queue, onOpenAsset: widget.openAsset);
    await _reload();
  }

  // ------------------------------------------------------------------ stats

  int get _backedUpCount => _records
      .where(
        (r) =>
            !r.isDeleted &&
            r.stateOf(DerivativeKind.original).status == UploadStatus.uploaded,
      )
      .length;

  int get _trackedCount => _records.where((r) => !r.isDeleted).length;

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
                padding: const EdgeInsets.only(top: 8, bottom: 32),
                // App data first: it's one switch, it needs no setup, and
                // it's the one that decides whether a reinstall starts from
                // nothing. Then how the photos sync, then the buckets they
                // sync to — the list of places belongs under the settings
                // that govern it, not above them.
                children: [
                  if (_icloudState != ICloudState.unsupported) ...[
                    _appDataSection(l10n),
                    const SettingsSectionDivider(),
                  ],
                  _syncSection(l10n, targets),
                  const SettingsSectionDivider(),
                  _bucketsSection(l10n, targets),
                ],
              ),
            ),
    );
  }

  /// One switch and nothing else. "Back up here" and "do it
  /// automatically" as separate toggles, plus a Sync Now beside them, is
  /// three controls for one decision and nobody can predict what any
  /// combination does.
  ///
  /// A container that can't work *right now* still shows its row: hiding it
  /// makes the feature invisible to exactly the person who needs telling
  /// about it. What changes is the line under the title — and only the one
  /// state the user can actually fix gets told how.
  Widget _appDataSection(AppLocalizations l10n) {
    final blocked = switch (_icloudState) {
      ICloudState.notEntitled => l10n.settingsICloudNotEntitled,
      ICloudState.driveOff => l10n.settingsICloudDriveOff,
      ICloudState.notReady => l10n.settingsICloudNotReady,
      ICloudState.available || ICloudState.unsupported => null,
    };
    final lastBackupAt = _icloudLastBackupAt;
    return SettingsSection(
      heading: l10n.settingsAppDataHeading,
      primary: false,
      hint: l10n.settingsAppDataHint,
      children: [
        SettingsRow(
          leading: const SettingsIconTile(icon: CupertinoIcons.cloud_upload),
          title: l10n.settingsICloudRow,
          // Says it once: a blocked row's reason *replaces* the location
          // line rather than being appended to it.
          subtitle: blocked ?? l10n.settingsICloudPath,
          detail: blocked != null
              ? null
              : lastBackupAt == null
              ? l10n.settingsICloudNever
              : l10n.settingsICloudLastBackup(_formatWhen(lastBackupAt)),
          trailing: _icloudBusy
              ? const CupertinoActivityIndicator(radius: 9)
              : CupertinoSwitch(
                  value: _icloudEnabled,
                  onChanged: _icloudState == ICloudState.available
                      ? _toggleICloud
                      : null,
                ),
        ),
        if (_icloudState == ICloudState.driveOff)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              settingsPagePadding,
              0,
              settingsPagePadding,
              8,
            ),
            child: Text(
              l10n.settingsICloudDriveOffFix,
              style: const TextStyle(fontSize: 12, color: settingsAccent),
            ),
          ),
      ],
    );
  }

  String _formatWhen(DateTime at) =>
      DateFormat.yMMMd().add_jm().format(at.toLocal());

  Widget _bucketsSection(AppLocalizations l10n, List<S3BackupTarget> targets) {
    return SettingsSection(
      heading: l10n.settingsCloudBucketsHeading,
      hint: l10n.settingsCloudBucketsHint,
      action: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        onPressed: _addBackup,
        child: const Icon(
          CupertinoIcons.add_circled_solid,
          size: 24,
          color: settingsAccent,
        ),
      ),
      footer: targets.isEmpty ? null : _bucketsFooter(l10n, targets),
      children: targets.isEmpty
          ? [_emptyState(l10n)]
          : [
              for (var i = 0; i < targets.length; i++) ...[
                if (i > 0) const SettingsHairline(indent: settingsRowIndent),
                SettingsRow(
                  leading: const SettingsIconTile(
                    icon: CupertinoIcons.cloud_fill,
                  ),
                  title: targets[i].bucket,
                  subtitle: _targetPath(targets[i]),
                  detail: targets[i].region,
                  onTap: () => _browse(targets[i]),
                  // No second tap target beside the row. The menu it used to
                  // open held Sync Now and Sync Queue, which are both on
                  // this page already, and Browse Files, which is what
                  // tapping the row does — leaving one real action, Delete
                  // Connection, which now lives on the connection's own
                  // screen.
                  trailing: const Icon(
                    CupertinoIcons.chevron_forward,
                    size: 14,
                    color: settingsSecondary,
                  ),
                ),
              ],
            ],
    );
  }

  Widget _bucketsFooter(AppLocalizations l10n, List<S3BackupTarget> targets) {
    return SettingsFooterLine(
      text: l10n.settingsCloudBucketsFooter(
        targets.length,
        _backedUpCount,
        _trackedCount,
      ),
      busy: _syncing,
      busyText: l10n.settingsSyncingMessage,
    );
  }

  /// The queue as one row, in with the rest of the sync controls. It's the
  /// answer to "is anything happening?", which is the most-asked question
  /// on this page and used to be the smallest thing on it.
  Widget _queueRow(AppLocalizations l10n) {
    final queue = widget.syncQueue;
    if (queue == null) {
      return SettingsRow(
        leading: const SettingsIconTile(
          icon: CupertinoIcons.arrow_2_circlepath,
        ),
        title: l10n.settingsSyncQueueRow,
        subtitle: l10n.backupQueueIdle,
      );
    }
    return ValueListenableBuilder<List<SyncJob>>(
      valueListenable: queue.jobs,
      builder: (context, jobs, _) {
        final pending = jobs.where((job) => !job.isFinished).length;
        return ValueListenableBuilder<bool>(
          valueListenable: queue.paused,
          builder: (context, paused, _) => ValueListenableBuilder<int>(
            valueListenable: queue.concurrency,
            builder: (context, concurrency, _) => SettingsRow(
              leading: const SettingsIconTile(
                icon: CupertinoIcons.arrow_2_circlepath,
              ),
              title: l10n.settingsSyncQueueRow,
              // The state in words under the title, so the switch doesn't
              // have to carry it: a bare "Paused" toggle leaves nobody sure
              // which way means running.
              subtitle: paused
                  ? l10n.backupQueuePausedNote
                  : pending == 0
                  ? l10n.backupQueueIdle
                  : l10n.settingsSyncQueuePending(pending, concurrency),
              onTap: _openQueue,
              // On is running. It sits on the queue's own row because
              // that's the thing it stops — a pause button off among the
              // actions read as one more thing to press rather than the
              // state of the list beside it.
              trailing: CupertinoSwitch(
                value: !paused,
                onChanged: (running) => queue.setPaused(!running),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _emptyState(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        settingsPagePadding,
        4,
        settingsPagePadding,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.settingsEmptyNote,
            style: const TextStyle(fontSize: 13, color: settingsSecondary),
          ),
          const SizedBox(height: 4),
          // The empty state carries the next action, not just a message.
          Align(
            alignment: Alignment.centerLeft,
            child: SettingsAccentButton(
              label: l10n.settingsAddButton,
              onPressed: _addBackup,
            ),
          ),
        ],
      ),
    );
  }

  /// One section for the whole of "how this app talks to the cloud": how
  /// often, the button that does it now, what gets uploaded, and what's
  /// queued. They were four separate headings, each with one control under
  /// it, which made a page of headings rather than a page of settings.
  Widget _syncSection(AppLocalizations l10n, List<S3BackupTarget> targets) {
    final lastSynced = _lastSyncAt == null
        ? l10n.settingsLastSyncedNever
        : l10n.settingsLastSyncedAt(
            DateFormat.MMMd().add_jm().format(_lastSyncAt!),
          );
    return SettingsSection(
      heading: l10n.settingsCloudSyncHeading.toUpperCase(),
      primary: false,
      hint: l10n.settingsSyncFrequencyHint,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(settingsPagePadding, 0, 16, 0),
          child: Text(lastSynced, style: settingsFooterStyle),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SettingsAccentButton(
              label: l10n.settingsBackupFormatLabel(
                _formatLabel(l10n, _format),
              ),
              onPressed: _pickFormat,
              showChevron: true,
            ),
          ),
        ),
        const SizedBox(height: 4),
        _queueRow(l10n),
        const SizedBox(height: 12),
        // The one thing you come to this page to press, under everything
        // that describes what it'll do. (Pause isn't here: it's the switch
        // on the queue's own row, because the queue is what it stops.)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: settingsPagePadding),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SettingsPillButton(
              icon: CupertinoIcons.arrow_2_circlepath,
              label: _syncing
                  ? l10n.settingsSyncingMessage
                  : l10n.settingsSyncNowButton,
              // Never a silent no-op: with nothing configured there is
              // nowhere to sync to, so the control stays visible but dead.
              onPressed: targets.isEmpty || _syncing ? null : _syncNow,
            ),
          ),
        ),
        const SizedBox(height: 10),
        // The standing arrangement, on its own line: how often it runs and
        // how hard it pushes. Pace used to live in the queue sheet, two
        // taps away from the schedule it belongs beside.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: settingsPagePadding),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SettingsPillButton(
                icon: CupertinoIcons.clock,
                label: l10n.settingsSyncSchedule(
                  _frequencyLabel(l10n, _frequency),
                ),
                onPressed: _pickFrequency,
              ),
              if (widget.syncQueue != null) _paceButtons(l10n),
            ],
          ),
        ),
      ],
    );
  }
}

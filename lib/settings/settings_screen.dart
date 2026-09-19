import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:intl/intl.dart';

import 'package:share_plus/share_plus.dart';

import '../backup/app_snapshot.dart';
import '../backup/bucket_backup.dart';
import '../backup/icloud_backup.dart';
import '../backup/icloud_drive.dart';
import '../backup/local_vault.dart';
import '../backup/snapshot_file.dart';
import '../l10n/app_localizations.dart';
import '../photos/person_store.dart';
import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import '../upload/backup_coordinator.dart';
import '../upload/sync_job.dart';
import '../upload/sync_queue.dart';
import '../viewer/sync_queue_sheet.dart';
import 'add_backup_screen.dart';
import 'backup_storage_type.dart';
import 'backup_targets_store.dart';
import 'bucket_browser_screen.dart';
import 'bucket_endpoint.dart';
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
    this.bucketBackup,
    this.vault,
    this.snapshotFile,
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

  /// One reader of the three stores, shared by every destination on this
  /// page. They each used to build their own, which meant three sets of
  /// database handles for one library.
  late final AppSnapshotIo _snapshots = AppSnapshotIo(
    assetRecordStore: _assetRecordStore,
    albumStore: AlbumStore(),
    personStore: PersonStore(),
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

  Future<void> _reloadBucketData() async {
    var enabled = false;
    DateTime? lastBackupAt;
    try {
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
      MaterialPageRoute(builder: (_) => AddBackupScreen(store: _store)),
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
      '${bucketUriScheme(target.provider)}://${target.bucket}/${target.prefix}';

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
  Widget _pacePill(AppLocalizations l10n) {
    final queue = widget.syncQueue!;
    return ValueListenableBuilder<int>(
      valueListenable: queue.concurrency,
      builder: (context, concurrency, _) => SettingsStepper(
        label: l10n.backupQueueSpeed(concurrency),
        decreaseSemanticLabel: l10n.backupQueueSlowerShort,
        increaseSemanticLabel: l10n.backupQueueFasterShort,
        onDecrease: concurrency <= 1
            ? null
            : () => queue.setConcurrency(concurrency - 1),
        onIncrease: () => queue.setConcurrency(concurrency + 1),
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

  int get _backedUpCount =>
      _records.where((r) => !r.isDeleted && r.isFullyBackedUp).length;

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
                // App data first: it needs no setup, and it's the part
                // that decides whether a reinstall starts from nothing.
                // Then the photos — the buckets and the settings that
                // govern them, which are one subject and now one section.
                children: [
                  _appDataSection(l10n, targets),
                  const SettingsSectionDivider(),
                  _cloudSection(l10n, targets),
                ],
              ),
            ),
    );
  }

  /// One switch per destination and nothing else. "Back up here" and "do
  /// it automatically" as separate toggles, plus a Sync Now beside them, is
  /// three controls for one decision and nobody can predict what any
  /// combination does.
  ///
  /// Two destinations, not a choice between them: iCloud needs no setup,
  /// the bucket is already paid for, and a copy in both is the whole point
  /// of offering both.
  ///
  /// A container that can't work *right now* still shows its row: hiding it
  /// makes the feature invisible to exactly the person who needs telling
  /// about it. What changes is the line under the title — and only the one
  /// state the user can actually fix gets told how.
  Widget _appDataSection(AppLocalizations l10n, List<S3BackupTarget> targets) {
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
        if (_icloudState != ICloudState.unsupported)
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
        if (_icloudState != ICloudState.unsupported)
          const SettingsHairline(indent: settingsRowIndent),
        SettingsRow(
          leading: const SettingsIconTile(icon: CupertinoIcons.archivebox_fill),
          title: l10n.settingsBucketDataRow,
          // Nothing to back up to says so where the switch is, rather
          // than letting a dead toggle explain itself.
          subtitle: targets.isEmpty
              ? l10n.settingsBucketDataNoBucket
              : l10n.settingsBucketDataPath,
          detail: targets.isEmpty
              ? null
              : _bucketDataLastBackupAt == null
              ? l10n.settingsICloudNever
              : l10n.settingsICloudLastBackup(
                  _formatWhen(_bucketDataLastBackupAt!),
                ),
          trailing: _bucketDataBusy
              ? const CupertinoActivityIndicator(radius: 9)
              : CupertinoSwitch(
                  value: _bucketDataEnabled,
                  onChanged: targets.isEmpty ? null : _toggleBucketData,
                ),
        ),
        const SizedBox(height: 14),
        _appDataFileControls(l10n),
      ],
    );
  }

  /// The manual door, as pills under the switches rather than as two more
  /// rows with switches of their own: these are things you press once, not
  /// arrangements you leave standing.
  ///
  /// The copy in the app's own container is a footer line, not a third
  /// switch. It shares the app's sandbox — deleting the app takes it and
  /// the library together — so listing it as a destination beside two that
  /// outlive the app would promise something it can't keep. What it can
  /// promise is the folder, so the folder is what the line names.
  Widget _appDataFileControls(AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: settingsPagePadding),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            SettingsPillButton(
              icon: CupertinoIcons.square_arrow_up,
              label: l10n.settingsAppDataExportButton,
              onPressed: _exporting ? null : _exportFile,
            ),
            SettingsPillButton(
              icon: CupertinoIcons.square_arrow_down,
              label: l10n.settingsAppDataRestoreButton,
              onPressed: _restoring ? null : _restoreFile,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(l10n.settingsAppDataLocalCopies, style: settingsFooterStyle),
      ],
    ),
  );

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
        content: Text(
          l10n.settingsAppDataRestoreConfirmBody(
            DateFormat.yMMMd().format(snapshot.exportedAt.toLocal()),
          ),
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

  /// Buckets and the settings that govern them, in one section. They were
  /// two headings for one subject, and the settings half had nothing to
  /// stand on without the list of places it was talking about.
  Widget _cloudSection(AppLocalizations l10n, List<S3BackupTarget> targets) {
    return SettingsSection(
      heading: l10n.settingsCloudHeading,
      hint: l10n.settingsCloudHint,
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
      footer: targets.isEmpty ? null : _cloudFooter(l10n, targets),
      children: [
        if (targets.isEmpty)
          _emptyState(l10n)
        else
          for (var i = 0; i < targets.length; i++) ...[
            if (i > 0) const SettingsHairline(indent: settingsRowIndent),
            SettingsRow(
              leading: const SettingsIconTile(icon: CupertinoIcons.cloud_fill),
              title: targets[i].bucket,
              subtitle: _targetPath(targets[i]),
              detail:
                  '${backupStorageTypeMeta(targets[i].provider).shortName} · ${targets[i].region}',
              onTap: () => _browse(targets[i]),
              // No second tap target beside the row. The menu it used to
              // open held Sync Now and Sync Queue, which are both on this
              // page already, and Browse Files, which is what tapping the
              // row does — leaving one real action, Delete Connection,
              // which now lives on the connection's own screen.
              trailing: const Icon(
                CupertinoIcons.chevron_forward,
                size: 14,
                color: settingsSecondary,
              ),
            ),
          ],
        if (targets.isNotEmpty) const SizedBox(height: 14),
        _syncControls(l10n, targets),
      ],
    );
  }

  /// Everything you do *to* the buckets above, in one block of pills under
  /// them: the verb first, then the standing arrangement — how often, how
  /// hard, what gets uploaded, and what's still owed.
  Widget _syncControls(AppLocalizations l10n, List<S3BackupTarget> targets) {
    final lastSynced = _lastSyncAt == null
        ? l10n.settingsLastSyncedNever
        : l10n.settingsLastSyncedAt(
            DateFormat.MMMd().add_jm().format(_lastSyncAt!),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: settingsPagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(lastSynced, style: settingsFooterStyle),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SettingsPillButton(
                icon: CupertinoIcons.arrow_2_circlepath,
                label: _syncing
                    ? l10n.settingsSyncingMessage
                    : l10n.settingsSyncNowButton,
                // Never a silent no-op: with nothing configured there is
                // nowhere to sync to, so the control stays visible but
                // dead.
                onPressed: targets.isEmpty || _syncing ? null : _syncNow,
              ),
              SettingsPillButton(
                icon: CupertinoIcons.clock,
                label: _frequencyLabel(l10n, _frequency),
                onPressed: _pickFrequency,
              ),
              if (widget.syncQueue != null) _queuePill(l10n),
              SettingsPillButton(
                icon: CupertinoIcons.photo,
                label: _formatLabel(l10n, _format),
                onPressed: _pickFormat,
              ),
              if (widget.syncQueue != null) _pacePill(l10n),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cloudFooter(AppLocalizations l10n, List<S3BackupTarget> targets) {
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

  /// The queue as a pill among the others, carrying its own count. What
  /// you do *to* the list — pause it, tidy it, empty it — is in the sheet
  /// it opens, beside the list those actions act on.
  Widget _queuePill(AppLocalizations l10n) {
    final queue = widget.syncQueue!;
    return ValueListenableBuilder<List<SyncJob>>(
      valueListenable: queue.jobs,
      builder: (context, jobs, _) {
        final pending = jobs.where((job) => !job.isFinished).length;
        return ValueListenableBuilder<bool>(
          valueListenable: queue.paused,
          builder: (context, paused, _) => SettingsPillButton(
            // Paused is a state you must be able to see without opening
            // anything — a stopped queue that looks exactly like a running
            // one is how uploads go missing for a week.
            icon: paused ? CupertinoIcons.pause_fill : CupertinoIcons.tray_full,
            label: paused
                ? l10n.backupQueuePausedNote
                : l10n.settingsSyncQueueButton(pending),
            onPressed: _openQueue,
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
}

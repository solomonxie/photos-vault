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
import '../l10n/failure_text.dart';
import '../photos/ai_analysis_store.dart';
import '../photos/conversation_store.dart';
import '../photos/person_owner.dart';
import '../photos/person_store.dart';
import '../viewer/owner_gate.dart';
import '../photos/travel_store.dart';
import '../sync/cloud_sync.dart';
import '../sync/log_sync.dart';
import '../sync/sync_store.dart';
import '../photos/words_store.dart';
import '../storage/album_store.dart';
import '../storage/asset_record_store.dart';
import 'add_backup_screen.dart';
import 'backup_targets_store.dart';
import 'bucket_browser_screen.dart';
import 'bucket_endpoint.dart';
import 's3_backup_target.dart';
import 'import_trash.dart';
import 'settings_section.dart';

/// "Cloud Settings": the buckets, the upload settings and the app-data
/// copies, each in its own inset group. Backing up runs on its own; what it
/// is doing shows under Suggestions. See
/// `docs/design/uiux/cloud-redesign.md`.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.store,
    this.assetRecordStore,
    this.icloudBackup,
    this.bucketBackup,
    this.vault,
    this.snapshotFile,
    this.personStore,
  });

  final BackupTargetsStore? store;
  final AssetRecordStore? assetRecordStore;

  /// Who "Me" can be. Optional so tests can hand in a fake.
  final PersonStore? personStore;

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
  late final PersonStore _personStore = widget.personStore ?? PersonStore();

  late final AppSnapshotIo _snapshots = AppSnapshotIo(
    assetRecordStore: _assetRecordStore,
    albumStore: AlbumStore(),
    personStore: _personStore,
    aiAnalysisStore: AiAnalysisStore(),
    conversationStore: ConversationStore(),
    wordsStore: WordsStore(),
    travelStore: TravelStore(),
    syncStore: SyncStore(),
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
      widget.snapshotFile ??
      SnapshotFile(
        snapshots: _snapshots,
        vault: _vault,
        fetchBlob: (sha, path) async =>
            await _icloudBackup.fetchBlob(sha, path) ||
            await _bucketBackup.fetchBlob(sha, path),
      );

  bool _exporting = false;
  bool _restoring = false;

  ICloudState _icloudState = ICloudState.unsupported;
  bool _icloudEnabled = false;
  DateTime? _icloudLastBackupAt;
  bool _icloudBusy = false;

  bool _bucketDataEnabled = false;
  DateTime? _bucketDataLastBackupAt;
  bool _bucketDataStale = false;
  bool _bucketDataBusy = false;

  List<S3BackupTarget>? _targets;
  int _waiting = 0;

  /// Waiting to Upload, counted again every few seconds while this page is
  /// on top: one COUNT query, nothing while another page covers it.
  late final Timer _waitingTimer = Timer.periodic(const Duration(seconds: 3), (
    _,
  ) {
    if (ModalRoute.of(context)?.isCurrent ?? false) _countWaiting();
  });

  Future<void> _countWaiting() async {
    try {
      final n = await _assetRecordStore.waitingUploadCount();
      if (mounted && n != _waiting) setState(() => _waiting = n);
    } catch (_) {
      // No library database: no number.
    }
  }

  BackupOrderStrategy _orderStrategy = BackupOrderStrategy.fileByFile;
  BackupFormat _format = BackupFormat.optimized;

  @override
  void initState() {
    super.initState();
    _reload();
    _reloadICloud();
    _reloadBucketData();
    _loadTrash();
    _loadOwner();
    _waitingTimer;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _waitingTimer.cancel();
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
    var stale = false;
    try {
      enabled = await _bucketBackup.isEnabled();
      lastBackupAt = await _bucketBackup.lastBackupAt();
      stale = await _bucketBackup.isStale();
    } catch (_) {
      // No database to remember the switch in — the row reads as off
      // rather than taking the screen down with it.
    }
    if (!mounted) return;
    setState(() {
      _bucketDataEnabled = enabled;
      _bucketDataLastBackupAt = lastBackupAt;
      _bucketDataStale = stale;
    });
  }

  /// Same bargain as the iCloud switch: turning it on writes the copy
  /// straight away, so the switch itself answers "did that work?".
  Future<void> _toggleBucketData(bool value) async {
    setState(() {
      _bucketDataEnabled = value;
      _bucketDataBusy = value;
    });
    Object? failure;
    try {
      await _bucketBackup.setEnabled(value);
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    setState(() => _bucketDataBusy = false);
    await _reloadBucketData();
    if (failure != null) await _tellFailure(failure);
  }

  Future<void> _reloadICloud() async {
    var state = ICloudState.unsupported;
    var enabled = false;
    DateTime? lastBackupAt;
    try {
      state = await _icloudBackup.drive.status();
      enabled = await _icloudBackup.isEnabled();
      if (state == ICloudState.available) {
        // This phone's own last copy. The folder's newest file is picked by
        // name, and an old `99999999-pre-deletion-…` copy outsorts every
        // daily, so it read Sep 24 for weeks of good copies.
        lastBackupAt =
            await _icloudBackup.schedule.lastRunAt() ??
            await _icloudBackup.drive.latestWriteAt();
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
    Object? failure;
    try {
      await _icloudBackup.setEnabled(value);
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    setState(() => _icloudBusy = false);
    await _reloadICloud();
    if (failure != null) await _tellFailure(failure);
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
    var format = BackupFormat.optimized;
    try {
      format = await _store.getBackupFormat();
    } catch (_) {
      // Same secure storage — the defaults are a working page.
    }
    await _countWaiting();
    if (!mounted) return;
    setState(() {
      _targets = targets;
      _orderStrategy = order;
      _format = format;
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
    try {
      if (await _bucketBackup.isEnabled()) {
        unawaited(_bucketBackup.backUpNow().catchError((_) => false));
      }
    } catch (_) {
      // Same as _reloadBucketData: no database, nothing to copy.
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
    try {
      // A stale listing would be trusted again if the bucket is re-added.
      await _assetRecordStore.forgetBucketListing(target.id);
    } catch (_) {
      // The next full listing replaces it anyway.
    }
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
    final before = _orderStrategy;
    setState(() => _orderStrategy = picked);
    try {
      await _store.setOrderStrategy(picked);
    } catch (e) {
      if (!mounted) return;
      setState(() => _orderStrategy = before);
      await _tellFailure(e);
    }
  }

  String _targetPath(S3BackupTarget target) =>
      '${bucketUriScheme(target.provider)}://${target.bucket}/${target.prefix}';

  // ------------------------------------------------------------------ build

  String _formatLabel(AppLocalizations l10n, BackupFormat f) => switch (f) {
    BackupFormat.original => l10n.settingsBackupFormatOriginal,
    BackupFormat.optimized => l10n.settingsBackupFormatOptimized,
  };

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
    final before = _format;
    setState(() => _format = picked);
    try {
      await _store.setBackupFormat(picked);
    } catch (e) {
      if (!mounted) return;
      setState(() => _format = before);
      await _tellFailure(e);
    }
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
                  SettingsGroupHeading(title: l10n.settingsMeHeading),
                  _meGroup(l10n),
                  const SizedBox(height: 28),
                  SettingsGroupHeading(title: l10n.cloudUploadsHeading),
                  _uploadsGroup(l10n, targets),
                  const SizedBox(height: 28),
                  SettingsGroupHeading(
                    title: l10n.settingsAppDataHeading,
                    onInfo: _explainAppData,
                  ),
                  _appDataGroup(l10n, targets),
                  if (CloudSync.instance case final sync?) ...[
                    const SizedBox(height: 28),
                    SettingsGroupHeading(title: l10n.syncHeading),
                    _syncGroup(l10n, targets, sync),
                  ],
                  const SizedBox(height: 28),
                  SettingsGroupHeading(title: l10n.settingsCloudBucketsHeading),
                  _bucketsGroup(l10n, targets),
                ],
              ),
            ),
    );
  }

  // ----------------------------------------------------------------- groups

  /// The owner's name, or null while nobody is set.
  String? _ownerName;

  Future<void> _loadOwner() async {
    try {
      final id = await PersonOwner(_assetRecordStore).id();
      final person = id == null ? null : await _personStore.getById(id);
      if (mounted) setState(() => _ownerName = person?.name);
    } catch (_) {
      // Reads as not set.
    }
  }

  Widget _meGroup(AppLocalizations l10n) => SettingsGroup(
    footer: l10n.settingsMeFooter,
    children: [
      SettingsGroupRow(
        key: const ValueKey('settingsMeRow'),
        title: l10n.settingsMeRow,
        value: _ownerName ?? l10n.settingsMeNotSet,
        chevron: true,
        onTap: () async {
          await pickOwner(
            context,
            store: _assetRecordStore,
            people: _personStore,
          );
          await _loadOwner();
        },
      ),
    ],
  );

  /// Chosen before the first sync; fixed after, since a different bucket
  /// is a different log (see `SyncStore.reset`).
  String? _syncHomeId;

  Widget _syncGroup(
    AppLocalizations l10n,
    List<S3BackupTarget> targets,
    CloudSync sync,
  ) => ValueListenableBuilder<CloudSyncStatus>(
    valueListenable: sync.status,
    builder: (context, s, _) {
      final homeId = s.homeTargetId ?? _syncHomeId;
      final home =
          targets.where((t) => t.id == homeId).firstOrNull ??
          targets.firstOrNull;
      final last = s.lastSyncedAt;
      final progress = s.progress;
      final subtitle = targets.isEmpty
          ? l10n.settingsBucketDataNoBucket
          : progress != null
          ? l10n.syncPublishing(progress)
          : s.fatal == SyncFatal.collision
          ? l10n.syncStoppedCollision
          : s.fatal == SyncFatal.newerProtocol
          ? l10n.syncStoppedNewer
          : s.error ??
                (last == null
                    ? l10n.syncNever
                    : l10n.syncLastSynced(_formatWhen(last)));
      return SettingsGroup(
        footer: l10n.syncFooter,
        children: [
          SettingsGroupRow(
            title: l10n.syncRow,
            subtitle: subtitle,
            trailing: s.busy
                ? const CupertinoActivityIndicator(radius: 9)
                : CupertinoSwitch(
                    value: s.enabled,
                    onChanged: home == null
                        ? null
                        : (on) =>
                              unawaited(on ? sync.enable(home) : sync.pause()),
                  ),
          ),
          if (home != null && targets.length > 1)
            SettingsGroupRow(
              title: l10n.syncHomeBucket,
              value: home.bucket,
              chevron: s.homeTargetId == null,
              onTap: s.homeTargetId == null
                  ? () => _pickSyncHome(targets)
                  : null,
            ),
          if (s.waiting > 0)
            SettingsGroupRow(title: l10n.syncWaiting, value: '${s.waiting}'),
          if (s.conflicts > 0)
            SettingsGroupRow(
              title: l10n.syncConflicts,
              value: '${s.conflicts}',
            ),
          if (s.enabled)
            SettingsGroupRow(
              title: l10n.syncNow,
              accent: true,
              onTap: s.busy ? null : () => unawaited(sync.round()),
            ),
        ],
      );
    },
  );

  Future<void> _pickSyncHome(List<S3BackupTarget> targets) async {
    final picked = await showCupertinoModalPopup<String>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        actions: [
          for (final t in targets)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.of(context).pop(t.id),
              child: Text(t.bucket),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(CupertinoLocalizations.of(context).cancelButtonLabel),
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _syncHomeId = picked);
  }

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
          if (targets.isNotEmpty && _waiting > 0)
            SettingsGroupRow(
              key: const ValueKey('cloudWaitingUpload'),
              title: l10n.cloudWaitingUpload,
              value: NumberFormat.decimalPattern().format(_waiting),
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
        footer: l10n.cloudAutoBackupFooter,
        children: [
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
        if (_bucketDataStale && bucketAt != null && targets.isNotEmpty)
          _WarnLine(
            l10n.settingsBucketDataStale(
              DateTime.now().difference(bucketAt).inDays,
            ),
          ),
        if (_trashBytes > 0)
          SettingsGroupRow(
            key: const ValueKey('settingsEmptyImportTrash'),
            title: l10n.settingsEmptyImportTrash,
            subtitle: l10n.settingsEmptyImportTrashHint(_mb(_trashBytes)),
            trailing: const Icon(
              CupertinoIcons.trash,
              size: 20,
              color: CupertinoColors.systemRed,
            ),
            onTap: _emptyImportTrash,
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

  final _importTrash = ImportTrash();
  int _trashBytes = 0;

  static String _mb(int bytes) => bytes >= 1e9
      ? '${(bytes / 1e9).toStringAsFixed(1)} GB'
      : '${(bytes / 1e6).toStringAsFixed(0)} MB';

  Future<void> _loadTrash() async {
    try {
      final bytes = await _importTrash.size();
      if (mounted) setState(() => _trashBytes = bytes);
    } catch (_) {}
  }

  Future<void> _emptyImportTrash() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: Text(l10n.settingsEmptyImportTrash),
        content: Text(l10n.settingsEmptyImportTrashBody(_mb(_trashBytes))),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            key: const ValueKey('settingsEmptyImportTrashConfirm'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.actionDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _importTrash.empty();
    } catch (e) {
      if (mounted) await _tellFailure(e);
    }
    await _loadTrash();
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
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      if (mounted) await _tellFailure(e);
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
      await _reloadBucketData();
      await _reloadICloud();
    } catch (e) {
      if (mounted) await _tellFailure(e);
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

  Future<void> _tellFailure(Object error) =>
      _tell(failureText(AppLocalizations.of(context)!, error));

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
/// A destination falling behind, said under its row in orange.
class _WarnLine extends StatelessWidget {
  const _WarnLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('settingsBucketDataStale'),
    padding: const EdgeInsets.fromLTRB(
      settingsPagePadding,
      0,
      settingsPagePadding,
      10,
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: CupertinoColors.systemOrange),
    ),
  );
}

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

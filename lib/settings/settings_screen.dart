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
import '../photos/ai_analysis_store.dart';
import '../photos/person_store.dart';
import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'add_backup_screen.dart';
import 'backup_storage_type.dart';
import 'backup_targets_store.dart';
import 'bucket_browser_screen.dart';
import 'bucket_endpoint.dart';
import 's3_backup_target.dart';
import 'settings_section.dart';

/// "Cloud Settings" — one flat page: the bucket list up top, then the
/// settings that govern syncing it. Nothing here pushes a sub-page that
/// only holds connections: where the copies go, and how to add another.
/// What the upload is *doing* — the queue, the schedule, Sync Now — is the
/// Sync Queue's own page, so this one answers one question rather than two.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.store,
    this.assetRecordStore,
    this.icloudBackup,
    this.bucketBackup,
    this.vault,
    this.snapshotFile,
  });

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

  List<S3BackupTarget>? _targets;
  List<AssetRecord> _records = const [];
  BackupOrderStrategy _orderStrategy = BackupOrderStrategy.fileByFile;

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
      _orderStrategy = order;
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
                  _removeAppDataButton(l10n),
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
        if (targets.isNotEmpty) _orderControl(l10n, targets.length > 1),
      ],
    );
  }

  /// The one thing about the list that isn't a single connection: which
  /// way it's worked through. It sits under the buckets it's talking
  /// about rather than with the queue's pills, because it's a property of
  /// having more than one bucket.
  ///
  /// With one bucket both orders are the same upload in the same order, so
  /// the pill is dimmed rather than hidden: a setting nobody can find
  /// until they've already built the situation it governs is a setting
  /// nobody knows to look for. What it can't do is offer a live choice
  /// that changes nothing — hence the line saying when it starts to count.
  Widget _orderControl(AppLocalizations l10n, bool enabled) => Padding(
    padding: const EdgeInsets.fromLTRB(settingsPagePadding, 12, 12, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsPillButton(
          icon: CupertinoIcons.arrow_2_squarepath,
          label: _orderLabel(l10n, _orderStrategy),
          onPressed: enabled ? _pickOrderStrategy : null,
        ),
        if (!enabled) ...[
          const SizedBox(height: 6),
          Text(
            l10n.settingsBucketOrderOneBucketNote,
            style: settingsFooterStyle,
          ),
        ],
      ],
    ),
  );

  Widget _cloudFooter(AppLocalizations l10n, List<S3BackupTarget> targets) {
    return SettingsFooterLine(
      text: l10n.settingsCloudBucketsFooter(
        targets.length,
        _backedUpCount,
        _trackedCount,
      ),
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

  Widget _removeAppDataButton(AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Center(
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: Size.zero,
        onPressed: _confirmRemoveAppData,
        child: Text(
          l10n.settingsRemoveAllAppDataButton,
          style: const TextStyle(color: CupertinoColors.systemRed),
        ),
      ),
    ),
  );

  Future<void> _confirmRemoveAppData() async {
    final l10n = AppLocalizations.of(context)!;
    await showCupertinoDialog<void>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text(l10n.settingsRemoveAllAppDataTitle),
        content: Text(l10n.settingsRemoveAllAppDataBody),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.actionCancel),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.settingsRemoveAllAppDataConfirm),
          ),
        ],
      ),
    );
  }
}

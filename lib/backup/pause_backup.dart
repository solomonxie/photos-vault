import 'dart:async';

import 'package:flutter/services.dart';

import 'app_snapshot.dart';
import 'bucket_backup.dart';
import 'icloud_backup.dart';
import 'icloud_drive.dart';
import 'local_vault.dart';
import 'snapshot_archive.dart';

/// Time iOS grants an app that just left the foreground, asked for through
/// `beginBackgroundTask` (in `ICloudDriveChannel.swift`). Without it the
/// process can be suspended mid-upload, and the day's copy never lands.
class BackgroundTime {
  const BackgroundTime({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(ICloudDrive.channelName);

  final MethodChannel _channel;

  Future<T> during<T>(Future<T> Function() work) async {
    int? id;
    try {
      id = await _channel.invokeMethod<int>('beginBackgroundTask');
    } catch (_) {
      // No channel (tests) or no time to be had: the work runs regardless.
    }
    try {
      return await work();
    } finally {
      if (id != null) {
        try {
          await _channel.invokeMethod<void>('endBackgroundTask', {'id': id});
        } catch (_) {}
      }
    }
  }
}

/// The app-data copy a pause owes: built once and handed to each
/// destination that is due, zipped off the UI isolate, inside the time iOS
/// grants on the way out. A pause while one is running joins it.
class PauseBackup {
  PauseBackup({
    required this.snapshots,
    required this.vault,
    required this.icloud,
    required this.bucket,
    this.time = const BackgroundTime(),
  });

  final AppSnapshotIo snapshots;
  final LocalVault vault;
  final ICloudBackup icloud;
  final BucketBackup bucket;
  final BackgroundTime time;

  Future<void>? _running;

  Future<void> run() =>
      _running ??= time.during(_run).whenComplete(() => _running = null);

  Future<void> _run() async {
    final vaultDue = await _ask(vault.schedule.isDue);
    final icloudDue = await _ask(
      () async => await icloud.isEnabled() && await icloud.schedule.isDue(),
    );
    final bucketDue = await _ask(
      () async => await bucket.isEnabled() && await bucket.schedule.isDue(),
    );
    if (!vaultDue && !icloudDue && !bucketDue) return;
    final SnapshotPayload payload;
    try {
      payload = await SnapshotPayload.build(snapshots);
    } catch (_) {
      return;
    }
    await Future.wait([
      if (vaultDue) _quietly(() => vault.copyNow(payload: payload)),
      if (icloudDue) _quietly(() => icloud.backUpNow(payload: payload)),
      if (bucketDue) _quietly(() => bucket.backUpNow(payload: payload)),
    ]);
  }

  static Future<bool> _ask(Future<bool> Function() question) async {
    try {
      return await question();
    } catch (_) {
      return false;
    }
  }

  /// Unattended: a destination that fails tries again on the next pause.
  static Future<void> _quietly(Future<bool> Function() write) async {
    try {
      await write();
    } catch (_) {}
  }
}

/// Of every destination, the copy a fresh install restores: a pre-deletion
/// copy first, then the newest `exportedAt` — not whichever was asked first.
/// Both are marked restored, so neither layers its copy on later. Returns
/// how many photos' records came back.
///
/// [scannedRows]: this launch began on an empty library, so rows a scan
/// added since don't make it any less fresh (see
/// [AppSnapshotIo.isFreshInstall]).
Future<int> restoreNewestOnFreshInstall({
  required ICloudBackup icloud,
  required BucketBackup bucket,
  bool scannedRows = false,
}) async {
  Future<RestoreCandidate?> ask(Future<RestoreCandidate?> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return null;
    }
  }

  final fromICloud = ask(
    () => icloud.candidateForFreshInstall(scannedRows: scannedRows),
  );
  final fromBucket = ask(
    () => bucket.candidateForFreshInstall(scannedRows: scannedRows),
  );
  final i = await fromICloud;
  final b = await fromBucket;
  final best = RestoreCandidate.best([i, b]);
  if (best == null) return 0;
  final restored = identical(best, i)
      ? await icloud.restoreFrom(best.snapshot)
      : await bucket.restoreFrom(best.snapshot);
  try {
    if (identical(best, i)) {
      await bucket.markRestored();
    } else {
      await icloud.markRestored();
    }
  } catch (_) {
    // The other's own guard still sees a library that isn't fresh.
  }
  return restored;
}

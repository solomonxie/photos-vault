import '../storage/asset_record_store.dart';
import 'app_snapshot.dart';

/// One gate, every off-device destination: **daily, and only if something
/// changed.**
///
/// "Something changed" is the change log's high-water mark, not a
/// timestamp and not a diff — a number that only moves when a user-authored
/// row is written. See `change_log.dart`.
///
/// Kept per destination, because they fail independently: iCloud being
/// unreachable for a week must not make the bucket think it is up to date.
///
/// The mark is recorded **only after a successful upload**. Record it
/// before, and a failed upload is remembered as done: the next day's gate
/// sees no change, skips, and goes on skipping indefinitely.
class BackupSchedule {
  BackupSchedule({
    required this.settings,
    required this.snapshots,
    required this.markKey,
    required this.atKey,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AssetRecordStore settings;
  final AppSnapshotIo snapshots;

  /// Where the last *successful* upload's high-water mark is kept.
  final String markKey;

  /// Where that upload's timestamp is kept — also what the settings row
  /// shows as "last copy".
  final String atKey;

  final DateTime Function() _now;

  Future<bool> isDue() async {
    final last = await lastRunAt();
    if (last != null && _isSameDay(last, _now())) return false;
    final recorded =
        int.tryParse(await settings.getAppState(markKey) ?? '') ?? -1;
    return await snapshots.changeMark() != recorded;
  }

  Future<DateTime?> lastRunAt() async {
    final raw = await settings.getAppState(atKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// [complete] false: a copy landed but still owes something (blobs
  /// mid-upload). The time moves, the mark doesn't, so tomorrow's gate
  /// runs again.
  Future<void> recordSuccess({bool complete = true}) async {
    if (complete) {
      await settings.setAppState(markKey, '${await snapshots.changeMark()}');
    }
    await settings.setAppState(atKey, _now().toIso8601String());
  }

  /// Nothing worth sending (an empty library): settled until it changes,
  /// without claiming a copy was made.
  Future<void> recordNothingToSend() async =>
      settings.setAppState(markKey, '${await snapshots.changeMark()}');

  /// The last copy is older than [after] and changes have been made since —
  /// the destination is falling behind, not merely idle.
  Future<bool> isStale({Duration after = staleAfter}) async {
    final last = await lastRunAt();
    if (last == null || _now().difference(last) <= after) return false;
    final recorded =
        int.tryParse(await settings.getAppState(markKey) ?? '') ?? -1;
    return await snapshots.changeMark() != recorded;
  }

  static const staleAfter = Duration(days: 3);
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

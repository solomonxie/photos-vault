import 'package:flutter/foundation.dart';

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';

/// Backs up every unlocked album's hidden photos, one at a time, for as
/// long as the app runs — started when an album opens and again at launch,
/// carrying on after the album closes. Nothing outside an album shows it.
class HiddenBackup {
  HiddenBackup({
    required this.records,
    required this.backUp,
    required this.albums,
    required this.ready,
    this.concurrency = 1,
    this.rest = const Duration(seconds: 2),
    this.stopped,
    this.before,
  });

  /// Run at the start of each pass, e.g. taking on photos a Mac sent
  /// ([MacUploads]), so they aren't counted as owed.
  final Future<void> Function()? before;

  /// Photos built and sent at once. One, with [rest] between: three at a
  /// time ran the phone hot and drained the battery (Nov 2026).
  final int concurrency;

  /// Idle time after each photo, so a long backlog is a trickle, not a
  /// sustained load.
  final Duration rest;

  /// Checked between photos: a background run ends when its time is up.
  final bool Function()? stopped;

  final AssetRecordStore records;
  final Future<void> Function(AssetRecord record) backUp;

  /// Passcode hashes of the albums with a key on hand.
  final Iterable<String> Function() albums;

  /// Whether there is a bucket at all; without one nothing is tried.
  final Future<bool> Function() ready;

  /// The photo going up right now.
  final uploading = ValueNotifier<String?>(null);

  /// Why a photo didn't go up on the last try, by local id.
  final problems = ValueNotifier<Map<String, String>>(const {});

  /// Ticks whenever a photo's status may have changed.
  final changed = ValueNotifier<int>(0);

  bool _running = false;
  bool _again = false;

  /// Starts a pass, or asks the running one to look again when it ends.
  /// A photo that fails is tried once per pass, so an offline phone doesn't
  /// spin.
  Future<void> run() async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      do {
        _again = false;
        if (!await ready()) return;
        try {
          await before?.call();
        } catch (_) {
          // Tried again next pass.
        }
        final failed = <String, String>{};
        final owed = [
          for (final hash in albums().toList())
            for (final record in await records.forPasscodeHash(hash))
              if (!record.isDeleted && !record.isFullyBackedUp) record,
        ];
        var next = 0;
        Future<void> worker() async {
          while (next < owed.length && !(stopped?.call() ?? false)) {
            final record = owed[next++];
            uploading.value = record.localId;
            try {
              await backUp(record);
            } catch (e) {
              failed[record.localId] = '$e';
            }
            changed.value++;
            if (rest > Duration.zero) await Future<void>.delayed(rest);
          }
        }

        await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
        problems.value = failed;
        if (stopped?.call() ?? false) return;
      } while (_again);
    } finally {
      uploading.value = null;
      _running = false;
    }
  }
}

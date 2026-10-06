import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/upload/background_sync.dart';

void main() {
  final now = DateTime(2026, 10, 5, 3);

  BackgroundSkip? decide({
    bool demo = false,
    SyncFrequency frequency = SyncFrequency.everyHour,
    bool hasTarget = true,
    DateTime? lastSyncAt,
    DateTime? foregroundAt,
    bool hasWork = true,
  }) => backgroundSkipReason(
    demo: demo,
    frequency: frequency,
    hasTarget: hasTarget,
    lastSyncAt: lastSyncAt,
    foregroundAt: foregroundAt,
    hasWork: hasWork,
    now: now,
  );

  test('runs when a bucket, a due frequency and pending work line up', () {
    expect(decide(), isNull);
  });

  test('demo mode never syncs in the background', () {
    expect(decide(demo: true), BackgroundSkip.demo);
  });

  test('Manual is a promise', () {
    expect(decide(frequency: SyncFrequency.manual), BackgroundSkip.manual);
  });

  test('needs a bucket', () {
    expect(decide(hasTarget: false), BackgroundSkip.noTarget);
  });

  test('stays out of the way of a foreground app', () {
    expect(
      decide(foregroundAt: now.subtract(const Duration(minutes: 2))),
      BackgroundSkip.foregroundRecent,
    );
    expect(
      decide(foregroundAt: now.subtract(const Duration(minutes: 6))),
      isNull,
    );
  });

  test('respects the frequency', () {
    expect(
      decide(lastSyncAt: now.subtract(const Duration(minutes: 30))),
      BackgroundSkip.notDue,
    );
    expect(decide(lastSyncAt: now.subtract(const Duration(hours: 2))), isNull);
  });

  test('does nothing with nothing pending', () {
    expect(decide(hasWork: false), BackgroundSkip.nothingToDo);
  });
}

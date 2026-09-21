import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/upload/sync_job.dart';
import 'package:photos_vault/upload/sync_queue.dart';
import 'package:photos_vault/viewer/backup_queue_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_sync_job_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

Widget _screen(SyncQueue queue, {Future<int> Function()? syncEverything}) =>
    BackupQueueScreen(
      queue: queue,
      settingsStore: BackupTargetsStore(store: FakeSecureStore()),
      syncEverything: syncEverything,
    );

void main() {
  // The in-memory fake, not the real ffi-backed store: its isolate
  // round-trips never resolve under `testWidgets`' fake async.
  SyncQueue newQueue({Future<void> Function(SyncJob job)? process}) {
    final store = FakeSyncJobStore();
    return SyncQueue(
      store: store,
      settings: BackupTargetsStore(store: FakeSecureStore()),
      // Never actually uploads: these tests are about what the queue shows.
      process: process ?? (_) async {},
    );
  }

  testWidgets('shows the empty state when nothing is queued', (tester) async {
    await tester.pumpWidget(_wrap(_screen(newQueue())));
    await tester.pumpAndSettle();

    expect(
      find.text("Nothing in the queue — everything's backed up."),
      findsOneWidget,
    );
  });

  testWidgets('lists every kind of work, labelled, not just uploads', (
    tester,
  ) async {
    final queue = newQueue();
    await queue.store.enqueue(
      localId: 'a',
      kind: SyncJobKind.uploadOriginal,
      displayName: 'beach.jpg',
      assetCreatedAt: DateTime(2024),
    );
    await queue.store.enqueue(
      localId: 'a',
      kind: SyncJobKind.uploadThumbnail,
      displayName: 'beach.jpg',
      assetCreatedAt: DateTime(2024),
    );
    await queue.store.enqueue(
      localId: 'b',
      kind: SyncJobKind.checkChanges,
      displayName: 'sunset.jpg',
      assetCreatedAt: DateTime(2024),
    );
    await queue.refresh();

    await tester.pumpWidget(_wrap(_screen(queue)));
    await tester.pumpAndSettle();

    expect(find.text('Queue (3)'), findsOneWidget);
    expect(find.text('Backing up original'), findsOneWidget);
    expect(find.text('Backing up thumbnail'), findsOneWidget);
    expect(find.text('Checking for changes'), findsOneWidget);
    expect(find.text('beach.jpg'), findsNWidgets(2));
    expect(find.text('Waiting'), findsNWidgets(3));
  });

  testWidgets('a failed job shows its error and can be retried', (
    tester,
  ) async {
    final queue = newQueue();
    final job = await queue.store.enqueue(
      localId: 'a',
      kind: SyncJobKind.uploadOriginal,
      displayName: 'beach.jpg',
      assetCreatedAt: DateTime(2024),
    );
    await queue.store.markFailed(job.id, 'Access denied');
    await queue.refresh();

    await tester.pumpWidget(_wrap(_screen(queue)));
    await tester.pumpAndSettle();

    expect(find.text('Access denied'), findsOneWidget);

    await tester.tap(find.byIcon(CupertinoIcons.arrow_clockwise_circle_fill));
    await tester.pumpAndSettle();

    expect(
      (await queue.store.all()).single.status,
      SyncJobStatus.done,
      reason: 'retried, then drained by the no-op processor',
    );
  });

  testWidgets('pausing is reflected in the toggle', (tester) async {
    final queue = newQueue();
    await queue.store.enqueue(
      localId: 'a',
      kind: SyncJobKind.uploadOriginal,
      displayName: 'beach.jpg',
      assetCreatedAt: DateTime(2024),
    );
    await queue.refresh();

    await tester.pumpWidget(_wrap(_screen(queue)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.pause_fill));
    await tester.pumpAndSettle();

    expect(queue.paused.value, isTrue);
    expect(find.byIcon(CupertinoIcons.play_fill), findsOneWidget);
  });

  testWidgets('Empty Queue clears the list outright', (tester) async {
    final queue = newQueue();
    await queue.store.enqueue(
      localId: 'a',
      kind: SyncJobKind.uploadOriginal,
      displayName: 'beach.jpg',
      assetCreatedAt: DateTime(2024),
    );
    final done = await queue.store.enqueue(
      localId: 'b',
      kind: SyncJobKind.uploadOriginal,
      displayName: 'sunset.jpg',
      assetCreatedAt: DateTime(2024),
    );
    await queue.store.markDone(done.id);
    await queue.refresh();

    await tester.pumpWidget(_wrap(_screen(queue)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Empty Queue'));
    await tester.pumpAndSettle();

    // Finished rows go too: the button says Empty, and a list still
    // holding a dozen green ticks reads as one that didn't work.
    expect(await queue.store.all(), isEmpty);
    expect(
      find.text("Nothing in the queue — everything's backed up."),
      findsOneWidget,
    );
  });

  testWidgets('the schedule and the format are pills of their values', (
    tester,
  ) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(BackupQueueScreen(queue: newQueue(), settingsStore: store)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Manual Only'), findsOneWidget);
    expect(find.text('Never synced'), findsOneWidget);

    await tester.tap(find.text('Manual Only'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Every Hour'));
    await tester.pumpAndSettle();

    expect(await store.getSyncFrequency(), SyncFrequency.everyHour);
  });

  testWidgets('Sync Now is present but dead when there is nothing behind it', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_screen(newQueue())));
    await tester.pumpAndSettle();

    // Present but disabled rather than missing — a manual action must
    // never be a silent no-op.
    final syncNow = tester.widget<CupertinoButton>(
      find.ancestor(
        of: find.text('Sync Now'),
        matching: find.byType(CupertinoButton),
      ),
    );
    expect(syncNow.onPressed, isNull);
  });

  testWidgets('Sync Now runs the sync and stamps the time', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    var ran = 0;
    await tester.pumpWidget(
      _wrap(
        BackupQueueScreen(
          queue: newQueue(),
          settingsStore: store,
          syncEverything: () async => ++ran,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sync Now'));
    await tester.pumpAndSettle();

    expect(ran, 1);
    expect(await store.getLastSyncAt(), isNotNull);
  });

  testWidgets('the speed stepper steps the queue concurrency', (tester) async {
    final queue = newQueue();
    await tester.pumpWidget(_wrap(_screen(queue)));
    await tester.pumpAndSettle();

    expect(find.text('2 at a time'), findsOneWidget);
    await tester.tap(find.byIcon(CupertinoIcons.plus));
    await tester.pumpAndSettle();

    expect(queue.concurrency.value, 3);
    expect(find.text('3 at a time'), findsOneWidget);
  });

  testWidgets('the backup format is one pill, and what each costs is in the '
      'sheet where it is chosen', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    await tester.pumpWidget(
      _wrap(BackupQueueScreen(queue: newQueue(), settingsStore: store)),
    );
    await tester.pumpAndSettle();

    // The page carries the current answer, not both answers and their
    // reasons laid out permanently.
    expect(find.textContaining('Full quality, byte-identical'), findsNothing);
    await tester.tap(find.text('Original'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Full quality, byte-identical'), findsOneWidget);
    expect(find.textContaining('Re-encodes photos as WebP'), findsOneWidget);
    await tester.tap(find.text('Optimized (WebP)'));
    await tester.pumpAndSettle();

    expect(await store.getBackupFormat(), BackupFormat.optimized);
    expect(find.text('Optimized (WebP)'), findsOneWidget);
  });
}

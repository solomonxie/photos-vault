import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/upload/sync_job.dart';
import 'package:photos_vault/upload/sync_queue.dart';
import 'package:photos_vault/viewer/sync_queue_sheet.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import '../settings/fake_secure_store.dart';
import '../support/fake_sync_job_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
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
    await tester.pumpWidget(_wrap(SyncQueueSheet(queue: newQueue())));
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
    );
    await queue.store.enqueue(
      localId: 'a',
      kind: SyncJobKind.uploadThumbnail,
      displayName: 'beach.jpg',
    );
    await queue.store.enqueue(
      localId: 'b',
      kind: SyncJobKind.checkChanges,
      displayName: 'sunset.jpg',
    );
    await queue.refresh();

    await tester.pumpWidget(_wrap(SyncQueueSheet(queue: queue)));
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
    );
    await queue.store.markFailed(job.id, 'Access denied');
    await queue.refresh();

    await tester.pumpWidget(_wrap(SyncQueueSheet(queue: queue)));
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
    );
    await queue.refresh();

    await tester.pumpWidget(_wrap(SyncQueueSheet(queue: queue)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.pause_fill));
    await tester.pumpAndSettle();

    expect(queue.paused.value, isTrue);
    expect(find.byIcon(CupertinoIcons.play_fill), findsOneWidget);
  });

  testWidgets(
    'Empty Queue drops what is waiting without touching anything else',
    (tester) async {
      final queue = newQueue();
      await queue.store.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'beach.jpg',
      );
      final done = await queue.store.enqueue(
        localId: 'b',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'sunset.jpg',
      );
      await queue.store.markDone(done.id);
      await queue.refresh();

      await tester.pumpWidget(_wrap(SyncQueueSheet(queue: queue)));
      await tester.pumpAndSettle();

      // The queue's controls are on the sheet now, not behind a "…".
      await tester.tap(find.text('Empty Queue'));
      await tester.pumpAndSettle();

      final remaining = await queue.store.all();
      expect(
        remaining.single.id,
        done.id,
        reason: 'finished rows stay; only the waiting one is dropped',
      );
    },
  );
}

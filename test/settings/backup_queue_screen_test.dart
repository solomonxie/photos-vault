import 'package:photos_vault/l10n/app_localizations.dart';
import 'package:photos_vault/settings/backup_queue_screen.dart';
import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/upload/sync_job.dart';
import 'package:photos_vault/upload/sync_queue.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_secure_store.dart';
import '../support/fake_sync_job_store.dart';

Widget _wrap(Widget child) => CupertinoApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

Widget _screen(
  SyncQueue queue, {
  Future<int> Function()? syncEverything,
  Future<void> Function(String localId)? onOpenAsset,
  BackupTargetsStore? store,
}) => BackupQueueScreen(
  queue: queue,
  settingsStore: store ?? BackupTargetsStore(store: FakeSecureStore()),
  syncEverything: syncEverything,
  onOpenAsset: onOpenAsset,
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

  Future<void> useTallSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  Future<SyncJob> enqueue(
    SyncQueue queue,
    String id,
    String name, {
    SyncJobKind kind = SyncJobKind.uploadOriginal,
  }) => queue.store.enqueue(
    localId: id,
    kind: kind,
    displayName: name,
    assetCreatedAt: DateTime(2024),
  );

  testWidgets('shows the empty state when nothing is queued', (tester) async {
    await tester.pumpWidget(_wrap(_screen(newQueue())));
    await tester.pumpAndSettle();

    expect(
      find.text("The queue is empty. Everything is backed up."),
      findsOneWidget,
    );
    expect(find.text('Backup Queue'), findsOneWidget);
  });

  testWidgets('lists every kind of work, labelled, in Up next', (tester) async {
    final queue = newQueue();
    await enqueue(queue, 'a', 'beach.jpg');
    await enqueue(queue, 'a', 'beach.jpg', kind: SyncJobKind.uploadThumbnail);
    await enqueue(queue, 'b', 'sunset.jpg', kind: SyncJobKind.checkChanges);
    await queue.refresh();

    await tester.pumpWidget(_wrap(_screen(queue)));
    await tester.pumpAndSettle();

    expect(find.text('UP NEXT · 3'), findsOneWidget);
    expect(find.text('Backing up original'), findsOneWidget);
    expect(find.text('Backing up thumbnail'), findsOneWidget);
    expect(find.text('Checking for changes'), findsOneWidget);
    expect(find.text('beach.jpg'), findsNWidgets(2));
    expect(find.text('Waiting'), findsNWidgets(3));
  });

  testWidgets('a failed job sits under Needs attention and can be retried', (
    tester,
  ) async {
    final queue = newQueue();
    final job = await enqueue(queue, 'a', 'beach.jpg');
    await queue.store.markFailed(job.id, 'Access denied');
    await queue.refresh();

    await tester.pumpWidget(_wrap(_screen(queue)));
    await tester.pumpAndSettle();

    expect(find.text('NEEDS ATTENTION · 1'), findsOneWidget);
    expect(find.text('Access denied'), findsOneWidget);

    await tester.tap(find.byIcon(CupertinoIcons.arrow_clockwise_circle_fill));
    await tester.pumpAndSettle();

    expect(
      (await queue.store.all()).single.status,
      SyncJobStatus.done,
      reason: 'retried, then drained by the no-op processor',
    );
  });

  testWidgets('Retry All retries every failed job', (tester) async {
    final queue = newQueue();
    for (final name in ['a', 'b']) {
      final job = await enqueue(queue, name, '$name.jpg');
      await queue.store.markFailed(job.id, 'boom');
    }
    await queue.refresh();

    await tester.pumpWidget(_wrap(_screen(queue)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry All'));
    await tester.pumpAndSettle();

    expect(
      (await queue.store.all()).every((j) => j.status == SyncJobStatus.done),
      isTrue,
    );
  });

  testWidgets('pausing is reflected in the bar and the summary', (
    tester,
  ) async {
    final queue = newQueue();
    await enqueue(queue, 'a', 'beach.jpg');
    await queue.refresh();

    await tester.pumpWidget(_wrap(_screen(queue)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.pause_fill));
    await tester.pumpAndSettle();

    expect(queue.paused.value, isTrue);
    expect(find.byIcon(CupertinoIcons.play_fill), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);
  });

  testWidgets('Empty Queue, from the menu, clears the list outright', (
    tester,
  ) async {
    final queue = newQueue();
    await enqueue(queue, 'a', 'beach.jpg');
    final done = await enqueue(queue, 'b', 'sunset.jpg');
    await queue.store.markDone(done.id);
    await queue.refresh();

    await tester.pumpWidget(_wrap(_screen(queue)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.ellipsis_circle));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Empty Queue'));
    await tester.pumpAndSettle();

    // Finished rows go too: the button says Empty, and a list still
    // holding a dozen green ticks reads as one that didn't work.
    expect(await queue.store.all(), isEmpty);
    expect(
      find.text("The queue is empty. Everything is backed up."),
      findsOneWidget,
    );
  });

  testWidgets('Clear on the Done section drops only finished rows', (
    tester,
  ) async {
    final queue = newQueue();
    await enqueue(queue, 'a', 'beach.jpg');
    final done = await enqueue(queue, 'b', 'sunset.jpg');
    await queue.store.markDone(done.id);
    await queue.refresh();

    await tester.pumpWidget(_wrap(_screen(queue)));
    await tester.pumpAndSettle();
    expect(find.text('DONE · 1'), findsOneWidget);

    await tester.tap(find.text('Clear Done'));
    await tester.pumpAndSettle();

    expect(find.text('DONE · 1'), findsNothing);
    expect((await queue.store.all()).single.localId, 'a');
  });

  testWidgets(
    'Back Up Now is present but dead when there is nothing behind it',
    (tester) async {
      await tester.pumpWidget(_wrap(_screen(newQueue())));
      await tester.pumpAndSettle();

      final button = tester.widget<CupertinoButton>(
        find.ancestor(
          of: find.text('Back Up Now'),
          matching: find.byType(CupertinoButton),
        ),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets('Back Up Now runs the sync and stamps the time', (tester) async {
    final store = BackupTargetsStore(store: FakeSecureStore());
    var ran = 0;
    await tester.pumpWidget(
      _wrap(
        _screen(newQueue(), store: store, syncEverything: () async => ++ran),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Never synced'), findsOneWidget);

    await tester.tap(find.text('Back Up Now'));
    await tester.pumpAndSettle();

    expect(ran, 1);
    expect(await store.getLastSyncAt(), isNotNull);
  });

  testWidgets('the speed stepper in the menu steps the concurrency', (
    tester,
  ) async {
    final queue = newQueue();
    await tester.pumpWidget(_wrap(_screen(queue)));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(CupertinoIcons.ellipsis_circle));
    await tester.pumpAndSettle();
    expect(find.text('2 at a time'), findsOneWidget);
    await tester.tap(find.byIcon(CupertinoIcons.plus));
    await tester.pumpAndSettle();

    expect(queue.concurrency.value, 3);
    expect(find.text('3 at a time'), findsOneWidget);
  });

  testWidgets('tapping a row opens that photo', (tester) async {
    final queue = newQueue();
    await enqueue(queue, 'photo-1', 'beach.jpg');
    await queue.refresh();
    String? opened;

    await tester.pumpWidget(
      _wrap(_screen(queue, onOpenAsset: (id) async => opened = id)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('beach.jpg'));

    expect(opened, 'photo-1');
  });

  testWidgets('a long section is capped, and Show more reveals the rest', (
    tester,
  ) async {
    await useTallSurface(tester);
    final queue = newQueue();
    for (var i = 0; i < 55; i++) {
      await enqueue(queue, 'id$i', 'photo$i.jpg');
    }
    await queue.refresh();

    await tester.pumpWidget(_wrap(_screen(queue)));
    await tester.pumpAndSettle();

    expect(find.text('Show 5 more'), findsOneWidget);
    await tester.tap(find.text('Show 5 more'));
    await tester.pumpAndSettle();
    expect(find.text('Show 5 more'), findsNothing);
  });
}

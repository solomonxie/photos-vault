import 'dart:async';

import 'package:photos_vault/settings/backup_targets_store.dart';
import 'package:photos_vault/upload/sync_job.dart';
import 'package:photos_vault/upload/sync_job_store.dart';
import 'package:photos_vault/upload/sync_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../settings/fake_secure_store.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  SyncJobStore newStore() {
    final store = SyncJobStore(
      databaseFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(store.close);
    return store;
  }

  group('SyncJobStore', () {
    test('enqueue is idempotent while a job is still outstanding', () async {
      final store = newStore();

      final first = await store.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'a.jpg',
      );
      final second = await store.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'a.jpg',
      );

      expect(second.id, first.id);
      expect(await store.all(), hasLength(1));
    });

    test('a different kind for the same asset is its own job', () async {
      final store = newStore();

      await store.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'a.jpg',
      );
      await store.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadThumbnail,
        displayName: 'a.jpg',
      );
      await store.enqueue(
        localId: 'a',
        kind: SyncJobKind.checkChanges,
        displayName: 'a.jpg',
      );

      expect(await store.all(), hasLength(3));
    });

    test('re-enqueues once the previous one finished', () async {
      final store = newStore();
      final first = await store.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'a.jpg',
      );
      await store.markDone(first.id);

      final second = await store.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'a.jpg',
      );

      expect(second.id, isNot(first.id));
      expect(await store.all(), hasLength(2));
    });

    test('dequeue claims a job so a second worker cannot take it', () async {
      final store = newStore();
      await store.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'a.jpg',
      );

      final claimed = await store.dequeueNextPending();
      final second = await store.dequeueNextPending();

      expect(claimed, isNotNull);
      expect(claimed!.status, SyncJobStatus.running);
      expect(second, isNull);
    });

    test(
      'clearQueue drops waiting and failed, keeps finished and running',
      () async {
        final store = newStore();
        final waiting = await store.enqueue(
          localId: 'a',
          kind: SyncJobKind.uploadOriginal,
          displayName: 'a.jpg',
        );
        final failed = await store.enqueue(
          localId: 'b',
          kind: SyncJobKind.uploadOriginal,
          displayName: 'b.jpg',
        );
        await store.markFailed(failed.id, 'nope');
        final done = await store.enqueue(
          localId: 'c',
          kind: SyncJobKind.uploadOriginal,
          displayName: 'c.jpg',
        );
        await store.markDone(done.id);

        await store.clearQueue();

        final ids = (await store.all()).map((j) => j.id).toList();
        expect(ids, [done.id]);
        expect(ids, isNot(contains(waiting.id)));
      },
    );

    test('clearSynced drops only the finished ones', () async {
      final store = newStore();
      final waiting = await store.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'a.jpg',
      );
      final done = await store.enqueue(
        localId: 'b',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'b.jpg',
      );
      await store.markDone(done.id);

      await store.clearSynced();

      expect((await store.all()).single.id, waiting.id);
    });

    test(
      'requeueStaleRunning rescues jobs orphaned by a kill mid-sync',
      () async {
        final store = newStore();
        await store.enqueue(
          localId: 'a',
          kind: SyncJobKind.uploadOriginal,
          displayName: 'a.jpg',
        );
        await store.dequeueNextPending();

        await store.requeueStaleRunning();

        expect((await store.all()).single.status, SyncJobStatus.pending);
      },
    );
  });

  group('SyncQueue', () {
    SyncQueue queueOver(
      SyncJobStore store,
      Future<void> Function(SyncJob) process,
    ) => SyncQueue(
      store: store,
      settings: BackupTargetsStore(store: FakeSecureStore()),
      process: process,
    );

    test('drains every queued job and marks them done', () async {
      final store = newStore();
      final processed = <String>[];
      final queue = queueOver(
        store,
        (job) async => processed.add(job.displayName),
      );
      for (final name in ['a.jpg', 'b.jpg', 'c.jpg']) {
        await queue.enqueue(
          localId: name,
          kind: SyncJobKind.uploadOriginal,
          displayName: name,
        );
      }

      await queue.start();

      expect(processed, hasLength(3));
      expect(
        (await store.all()).every((j) => j.status == SyncJobStatus.done),
        isTrue,
      );
    });

    test('runs jobs concurrently, bounded by the configured speed', () async {
      final store = newStore();
      var running = 0;
      var peak = 0;
      final queue = queueOver(store, (job) async {
        running++;
        peak = running > peak ? running : peak;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        running--;
      });
      await queue.setConcurrency(3);
      for (var i = 0; i < 6; i++) {
        await queue.enqueue(
          localId: '$i',
          kind: SyncJobKind.uploadOriginal,
          displayName: '$i.jpg',
        );
      }

      await queue.start();

      expect(peak, greaterThan(1), reason: 'not one-at-a-time');
      expect(
        peak,
        lessThanOrEqualTo(3),
        reason: 'never exceeds the configured bound',
      );
    });

    test('a thrown job is recorded as failed with its message, and the rest still run', () async {
      final store = newStore();
      final queue = queueOver(store, (job) async {
        if (job.displayName == 'bad.jpg') throw Exception('Access denied');
      });
      await queue.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'bad.jpg',
      );
      await queue.enqueue(
        localId: 'b',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'good.jpg',
      );

      await queue.start();

      final jobs = await store.all();
      final bad = jobs.firstWhere((j) => j.displayName == 'bad.jpg');
      final good = jobs.firstWhere((j) => j.displayName == 'good.jpg');
      expect(bad.status, SyncJobStatus.failed);
      expect(bad.errorMessage, contains('Access denied'));
      expect(good.status, SyncJobStatus.done);
    });

    test('paused does not drain, and resuming picks it back up', () async {
      final store = newStore();
      var processed = 0;
      final queue = queueOver(store, (_) async => processed++);
      // Queued before the pause — pausing now takes nothing new either
      // (see 'SyncQueue limits'), so what's already waiting is the whole
      // question.
      await queue.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'a.jpg',
      );
      await queue.setPaused(true);

      await queue.start();
      expect(processed, 0);

      await queue.setPaused(false);
      await queue.start();
      expect(processed, 1);
    });

    test('a job that queues more work keeps the drain going', () async {
      final store = newStore();
      late final SyncQueue queue;
      queue = queueOver(store, (job) async {
        // A change check that finds drift queues the re-upload itself.
        if (job.kind == SyncJobKind.checkChanges) {
          await queue.enqueue(
            localId: job.localId,
            kind: SyncJobKind.uploadOriginal,
            displayName: job.displayName,
          );
        }
      });
      await queue.enqueue(
        localId: 'a',
        kind: SyncJobKind.checkChanges,
        displayName: 'a.jpg',
      );

      await queue.start();

      final jobs = await store.all();
      expect(jobs, hasLength(2));
      expect(jobs.every((j) => j.status == SyncJobStatus.done), isTrue);
    });
  });

  group('SyncQueue limits', () {
    SyncQueue queueOver(SyncJobStore store) => SyncQueue(
      store: store,
      settings: BackupTargetsStore(store: FakeSecureStore()),
      process: (_) async {},
    );

    test('a paused queue takes nothing new', () async {
      final store = newStore();
      final queue = queueOver(store);
      await queue.setPaused(true);

      final taken = await queue.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'a.jpg',
      );

      expect(taken, isFalse);
      expect(await store.all(), isEmpty);
    });

    test('and takes them again once it resumes', () async {
      final store = newStore();
      final queue = queueOver(store);
      await queue.setPaused(true);
      await queue.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'a.jpg',
      );
      await queue.setPaused(false);

      expect(
        await queue.enqueue(
          localId: 'a',
          kind: SyncJobKind.uploadOriginal,
          displayName: 'a.jpg',
        ),
        isTrue,
      );
    });

    test('fills to capacity and then refuses', () async {
      final store = newStore();
      final queue = queueOver(store);

      for (var i = 0; i < SyncQueue.capacity; i++) {
        expect(
          await queue.enqueue(
            localId: 'a$i',
            kind: SyncJobKind.uploadOriginal,
            displayName: 'a$i.jpg',
          ),
          isTrue,
        );
      }

      expect(
        await queue.enqueue(
          localId: 'one-too-many',
          kind: SyncJobKind.uploadOriginal,
          displayName: 'x.jpg',
        ),
        isFalse,
      );
      expect(await queue.unfinishedCount(), SyncQueue.capacity);
    });

    test('a job that is done or failed is no longer in the way', () async {
      final store = newStore();
      final queue = queueOver(store);
      for (var i = 0; i < SyncQueue.capacity; i++) {
        await queue.enqueue(
          localId: 'a$i',
          kind: SyncJobKind.uploadOriginal,
          displayName: 'a$i.jpg',
        );
      }
      final jobs = await store.all();
      await store.markDone(jobs.first.id);
      await store.markFailed(jobs[1].id, 'nope');

      // Neither is work still to be done, so neither counts against the
      // cap. A failure holding its place would mean a hundred dead rows
      // silently blocking every future sync.
      expect(await queue.unfinishedCount(), SyncQueue.capacity - 2);
      expect(
        await queue.enqueue(
          localId: 'after-a-done-one',
          kind: SyncJobKind.uploadOriginal,
          displayName: 'x.jpg',
        ),
        isTrue,
      );
      expect(
        await queue.enqueue(
          localId: 'and-another',
          kind: SyncJobKind.uploadOriginal,
          displayName: 'y.jpg',
        ),
        isTrue,
      );
    });
  });

  group('a failure is retried, not duplicated', () {
    test('re-queueing a failed job resets it in place', () async {
      final store = newStore();
      final first = await store.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'a.jpg',
      );
      await store.markFailed(first.id, 'offline');

      final second = await store.enqueue(
        localId: 'a',
        kind: SyncJobKind.uploadOriginal,
        displayName: 'a.jpg',
      );

      expect(second.id, first.id, reason: 'the same row, not a second one');
      expect(await store.all(), hasLength(1));
      expect((await store.all()).single.status, SyncJobStatus.pending);
    });

    test('so a queue of failures does not grow every sync', () async {
      final store = newStore();
      final queue = SyncQueue(
        store: store,
        settings: BackupTargetsStore(store: FakeSecureStore()),
        process: (_) async => throw StateError('nope'),
      );
      for (var i = 0; i < 3; i++) {
        await queue.enqueue(
          localId: 'a$i',
          kind: SyncJobKind.uploadOriginal,
          displayName: 'a$i.jpg',
        );
      }
      await queue.start();
      expect(await store.countWhere([SyncJobStatus.failed]), 3);

      // What the next sync does.
      for (var i = 0; i < 3; i++) {
        await queue.enqueue(
          localId: 'a$i',
          kind: SyncJobKind.uploadOriginal,
          displayName: 'a$i.jpg',
        );
      }

      expect(await store.all(), hasLength(3));
    });
  });
}

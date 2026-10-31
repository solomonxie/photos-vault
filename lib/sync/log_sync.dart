import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:sqflite/sqflite.dart' show Database;

import 'capture.dart';
import 'checkpoint.dart';
import 'hlc.dart';
import 'log_bucket.dart';
import 'merge.dart';
import 'op.dart';
import 'segment.dart';
import 'sync_store.dart';
import 'translate.dart';

enum SyncFatal { collision, newerProtocol }

/// The phone's side of `docs/design/cloud-sync/PROTOCOL.md`:
///
/// ```text
/// store writes ─triggers─▶ sync_outbox (each store db)
///   ─collect─▶ sync.db outbox ─seal─▶ sealed segment ─flush─▶ bucket (write-once)
/// bucket segments ─pull─▶ merge state in sync.db ─▶ changed keys for the applier
/// ```
///
/// Stamps are given at sealing, and the outbox is always sealed before a
/// pulled segment is applied — so every op's version vector is exactly what
/// this phone knew when it was made, which is what keeps a real conflict
/// from being merged away.
class LogSync {
  LogSync({
    required this.store,
    required this.bucket,
    required this.sources,
    required this.privateAssets,
  });

  final SyncStore store;
  final LogBucket bucket;

  /// The store databases carrying capture triggers.
  final List<Future<Database> Function()> sources;

  /// Of these asset ids, the ones behind a passcode: their memberships stay here.
  final Future<Set<String>> Function(Set<String> ids) privateAssets;

  Future<void> _tail = Future.value();

  /// One sync step at a time in this isolate.
  Future<T> _locked<T>(Future<T> Function() body) {
    final run = _tail.then((_) => body());
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<Map<String, int>> _vv() async {
    final raw = await store.meta('vv');
    return raw == null ? {} : (jsonDecode(raw) as Map).cast<String, int>();
  }

  Future<Hlc> _hlc() async {
    final raw = await store.meta('hlc');
    return raw == null ? Hlc.zero : Hlc.parse(raw);
  }

  Future<int> _nextSeq() async =>
      int.parse(await store.meta('next_seq') ?? '1');

  Future<SyncFatal?> fatal() async {
    final raw = await store.meta('fatal');
    return raw == null ? null : SyncFatal.values.byName(raw);
  }

  Future<bool> hasCheckpoint() async =>
      await store.meta('checkpoint') == 'true';

  /// Captured store writes → `sync.db` outbox. The two databases can't share
  /// a transaction: a crash between them re-collects, and a repeated op is
  /// harmless (same value, or one more add tag).
  Future<int> collect() => _locked(_collect);

  Future<int> _collect() async {
    var moved = 0;
    for (final open in sources) {
      final db = await open();
      while (true) {
        final rows = await readCaptured(db);
        if (rows.isEmpty) break;
        final now = bucket.now();
        final changes = [
          for (final r in rows)
            ...translate(r.table, r.key, r.kind, r.before, r.after, now),
        ];
        final members = {
          for (final c in changes)
            if (c.f == 'members') c.x as String,
        };
        final hidden = members.isEmpty
            ? const <String>{}
            : await privateAssets(members);
        await store.addChanges([
          for (final c in changes)
            if (c.f != 'members' || !hidden.contains(c.x)) c,
        ]);
        await dropCaptured(db, rows.last.n);
        moved += changes.length;
      }
    }
    return moved;
  }

  /// Outbox → stamped, immutable local segments of at most [segmentMaxOps].
  Future<void> seal() => _locked(() async {
    await _collect();
    await _seal();
  });

  Future<void> _seal() async {
    final pending = await store.outbox();
    if (pending.isEmpty) return;
    final device = await store.device();
    final vv = await _vv();
    final others = {...vv}..remove(device);
    var hlc = await _hlc();
    var seq = await _nextSeq();
    final state = SyncState();
    await store.loadInto(state, {
      for (final (_, c) in pending) '${c.e}/${c.id}',
    });
    final sealed = <(int, List<int>)>[];
    for (var i = 0; i < pending.length; i += segmentMaxOps) {
      final part = pending.sublist(
        i,
        (i + segmentMaxOps).clamp(0, pending.length),
      );
      final ops = <Op>[];
      for (final (_, c) in part) {
        hlc = hlc.tick(bucket.now());
        final ts = c.o == OpKind.mrem
            ? [...?state.entities['${c.e}/${c.id}']?.sets[c.f]?[c.x]?.adds]
            : const <String>[];
        final op = Op(
          h: '$hlc',
          d: device,
          seq: seq,
          vv: others,
          e: c.e,
          id: c.id,
          o: c.o,
          f: c.f,
          x: c.x,
          ts: ts,
        );
        state.apply(op);
        ops.add(op);
      }
      sealed.add((
        seq,
        Segment(d: device, seq: seq, vv: others, ops: ops).encode(),
      ));
      seq++;
    }
    final last = pending.last.$1;
    await store.save(
      state,
      meta: {
        'hlc': '$hlc',
        'next_seq': seq,
        'vv': {...vv, device: seq - 1},
      },
      also: (batch) {
        for (final (s, bytes) in sealed) {
          batch.insert('sealed', {'seq': s, 'bytes': bytes});
        }
        batch.delete('outbox', where: 'n <= ?', whereArgs: [last]);
      },
    );
  }

  /// Sealed segments → bucket, in order, write-once. Returns how many went.
  Future<int> flush() => _locked(() async {
    if (await fatal() != null) return 0;
    await _collect();
    await _seal();
    final device = await store.device();
    var sent = 0;
    for (final (seq, bytes) in await store.sealed()) {
      final r = await bucket.putOnce(Segment.key(device, seq), bytes);
      if (r == PutOnce.collision) {
        await store.setMeta('fatal', SyncFatal.collision.name);
        break;
      }
      await store.dropSealed(seq);
      sent++;
    }
    return sent;
  });

  /// Other devices' new segments → merge state. Returns the keys
  /// (`asset/<id>`, …) whose merged values may have moved.
  Future<Set<String>> pull() => _locked(() async {
    await _collect();
    await _seal();
    final device = await store.device();
    final vv = await _vv();
    var hlc = await _hlc();
    final changed = <String>{};
    for (final folder in await bucket.folders('sync/log/')) {
      final d = folder.substring('sync/log/'.length, folder.length - 1);
      if (d == device) continue;
      final have = vv[d] ?? 0;
      final listed = await bucket.list(
        folder,
        startAfter: have > 0 ? Segment.key(d, have) : null,
      );
      final next = [
        for (final o in listed)
          if (Segment.seqOf(o.key) case final seq?) (seq, o),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      for (final (seq, o) in next) {
        if (seq != (vv[d] ?? 0) + 1) break;
        final Segment segment;
        try {
          segment = Segment.decode(
            await bucket.get(o.key),
            lastModified: o.lastModified,
          );
        } on NewerProtocol {
          await store.setMeta('fatal', SyncFatal.newerProtocol.name);
          break;
        }
        final state = SyncState()..vv.addAll(vv);
        await store.loadInto(state, {
          for (final op in segment.ops) '${op.e}/${op.id}',
        });
        state.touched.clear();
        if (!state.applySegment(segment)) break;
        vv[d] = seq;
        hlc = hlc.receive(state.seen);
        changed.addAll(state.touched);
        await store.save(state, meta: {'vv': vv, 'hlc': '$hlc'});
      }
    }
    return changed;
  });

  /// The newest checkpoint in the bucket, or null when there is none.
  Future<LogObject?> newestCheckpoint() async {
    final all = await bucket.list('sync/checkpoints/');
    final named = [
      for (final o in all)
        if (o.key.endsWith('.ndjson.gz')) o,
    ]..sort((a, b) => a.key.split('/').last.compareTo(b.key.split('/').last));
    return named.lastOrNull;
  }

  /// Replaces the local merge state with the bucket's newest checkpoint.
  Future<bool> adoptCheckpoint() => _locked(() async {
    final newest = await newestCheckpoint();
    if (newest == null) return false;
    final lines = const LineSplitter().convert(
      utf8.decode(gzip.decode(await bucket.get(newest.key))),
    );
    final head = jsonDecode(lines.first) as Map<String, Object?>;
    final v = head['v'] as int;
    if (v > protocolVersion) throw NewerProtocol(v);
    final vv = (head['vv'] as Map).cast<String, int>();
    final device = await store.device();
    // Its publisher's clock was past every stamp in it; ours must be too.
    final hlc = (await _hlc()).receive(Hlc.parse(head['h'] as String));
    await store.setMeta('hlc', '$hlc');
    // Ours as far as the bucket has it; anything sealed later is ours to send.
    final mine = (await _vv())[device];
    await store.adopt(lines.skip(1).where((l) => l.isNotEmpty), {
      ...vv,
      device: ?mine,
    });
    return true;
  });

  /// The whole merge state, published as a checkpoint other devices start from.
  Future<String> publishCheckpoint() => _locked(() async {
    final device = await store.device();
    final hlc = (await _hlc()).tick(bucket.now());
    final vv = await _vv();
    final lines = <String>[
      jsonEncode({'v': protocolVersion, 'd': device, 'h': '$hlc', 'vv': vv}),
      await for (final l in store.allLines()) l,
    ];
    final key = Checkpoint.key(device, hlc);
    final r = await bucket.putOnce(
      key,
      gzip.encode(utf8.encode(lines.join('\n'))),
    );
    if (r == PutOnce.collision) {
      throw StateError('checkpoint collision at $key');
    }
    await store.setMeta('hlc', '$hlc');
    return key;
  });
}

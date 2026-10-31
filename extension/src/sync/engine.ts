import type { ListedObject } from '../bucket/client';
import { getAll, openDb, request, tx } from '../store/idb';
import { checkpointHeader, decodeCheckpoint, decodeCheckpointLines, entityLine } from './checkpoint';
import { type Hlc, compare, format, parse, tick, zero } from './hlc';
import { SyncState } from './merge';
import type { Op, VersionVector, WireOp } from './op';
import { NewerProtocol, decodeSegment, encodeSegment, segmentKey, segmentMaxOps, seqOf } from './segment';

/// What the engine needs from a bucket; `Bucket` has it, tests fake it.
export interface LogBucket {
  list(prefix: string, opts?: { startAfter?: string; delimiter?: string }): Promise<{ objects: ListedObject[]; prefixes: string[] }>;
  get(key: string): Promise<Uint8Array>;
  put(key: string, body: Uint8Array, contentType?: string): Promise<void>;
  putOnce(key: string, body: Uint8Array): Promise<'written' | 'exists-same' | 'collision'>;
  now(): number;
}

export type Change = Omit<WireOp, 'h'>;
export type Fatal = 'collision' | 'newer-protocol' | null;

const lockName = 'photos-vault-sync';

/// One writer per Chrome profile, across tabs: every mutation runs under a Web Lock.
const locked = <T>(fn: () => Promise<T>): Promise<T> =>
  typeof navigator !== 'undefined' && navigator.locks
    ? (navigator.locks.request(lockName, fn) as Promise<T>)
    : fn();

/// The browser's side of PROTOCOL.md: local edits → outbox → sealed segments →
/// bucket; bucket segments → merge → IndexedDB. Local write and its outbox
/// entry commit in one IndexedDB transaction.
export class Engine {
  state = new SyncState();
  private hlc: Hlc = zero;
  private nextSeq = 1;
  private generation = 0;
  fatal: Fatal = null;
  hasCheckpoint = false;

  private constructor(
    readonly db: IDBDatabase,
    readonly bucket: LogBucket,
    readonly device: string,
  ) {}

  static async open(bucket: LogBucket, opts: { dbName?: string; deviceName?: string } = {}): Promise<Engine> {
    const db = await openDb(opts.dbName);
    const meta = new Map(await getAll<unknown>(db, 'meta'));
    let device = meta.get('device') as string | undefined;
    if (!device) {
      device = crypto.randomUUID();
      const { objects } = await bucket.list(`sync/log/${device}/`);
      if (objects.length > 0) throw new Error(`device id ${device} already has a log`);
      await bucket.put(
        `sync/devices/${device}.json`,
        new TextEncoder().encode(
          JSON.stringify({ device, name: opts.deviceName ?? 'Chrome', kind: 'browser', created: bucket.now() }),
        ),
        'application/json',
      );
      await tx(db, ['meta'], (t) => t.objectStore('meta').put(device, 'device'));
    }
    const engine = new Engine(db, bucket, device);
    await engine.reload();
    return engine;
  }

  private async reload() {
    const meta = new Map(await getAll<unknown>(this.db, 'meta'));
    const lines = (await getAll<string>(this.db, 'entities')).map(([, l]) => l);
    this.state = decodeCheckpointLines([
      JSON.stringify({ v: 1, vv: (meta.get('vv') as VersionVector | undefined) ?? {} }),
      ...lines,
    ]);
    this.state.touched.clear();
    this.hlc = meta.has('hlc') ? parse(meta.get('hlc') as string) : zero;
    this.nextSeq = (meta.get('nextSeq') as number | undefined) ?? 1;
    this.generation = (meta.get('generation') as number | undefined) ?? 0;
    this.fatal = (meta.get('fatal') as Fatal | undefined) ?? null;
    this.hasCheckpoint = meta.get('checkpoint') === true;
  }

  /// Another tab may have written since: reload rather than act on stale memory.
  private async fresh() {
    const t = this.db.transaction('meta', 'readonly').objectStore('meta');
    const gen = ((await request(t.get('generation'))) as number | undefined) ?? 0;
    if (gen !== this.generation) await this.reload();
  }

  private vvOthers(): VersionVector {
    const { [this.device]: _self, ...rest } = this.state.vv;
    return rest;
  }

  private persist(t: IDBTransaction) {
    const entities = t.objectStore('entities');
    for (const key of this.state.touched) {
      const ent = this.state.entities.get(key);
      if (ent) entities.put(entityLine(ent), key);
    }
    this.state.touched.clear();
    const meta = t.objectStore('meta');
    this.generation++;
    meta.put(this.generation, 'generation');
    meta.put(format(this.hlc), 'hlc');
    meta.put(this.nextSeq, 'nextSeq');
    meta.put(this.state.vv, 'vv');
    meta.put(this.fatal, 'fatal');
    meta.put(this.hasCheckpoint, 'checkpoint');
  }

  private async outboxSize() {
    return request(this.db.transaction('outbox', 'readonly').objectStore('outbox').count());
  }

  /// Applies `changes` locally and queues them, atomically.
  edit(changes: Change[]): Promise<void> {
    return locked(async () => {
      await this.fresh();
      // Before the phone has published the library there is nothing to edit,
      // and a browser-started library could not be merged with it.
      if (!this.hasCheckpoint) throw new Error('no library checkpoint yet');
      if ((await this.outboxSize()) + changes.length > segmentMaxOps) await this.sealLocked();
      const vv = this.vvOthers();
      const ops: Op[] = changes.map((c) => {
        this.hlc = tick(compare(this.hlc, this.state.seen) >= 0 ? this.hlc : this.state.seen, this.bucket.now());
        return { ...c, h: format(this.hlc), d: this.device, seq: this.nextSeq, vv };
      });
      for (const op of ops) this.state.apply(op);
      try {
        await tx(this.db, ['outbox', 'entities', 'meta'], (t) => {
          const outbox = t.objectStore('outbox');
          for (const { d: _d, seq: _s, vv: _v, ...wire } of ops) outbox.add(wire);
          this.persist(t);
        });
      } catch (e) {
        await this.reload();
        throw e;
      }
    });
  }

  /// Outbox → one immutable local segment. Always before applying pulled ops,
  /// so every op's `vv` is exactly what its device knew.
  seal(): Promise<void> {
    return locked(async () => {
      await this.fresh();
      await this.sealLocked();
    });
  }

  private async sealLocked() {
    const pending = await getAll<WireOp>(this.db, 'outbox');
    if (pending.length === 0) return;
    const seq = this.nextSeq;
    const vv = this.vvOthers();
    const bytes = await encodeSegment({
      d: this.device,
      seq,
      vv,
      ops: pending.map(([, w]) => ({ ...w, d: this.device, seq, vv })),
      lastModified: 0,
    });
    this.nextSeq = seq + 1;
    this.state.vv[this.device] = seq;
    await tx(this.db, ['outbox', 'sealed', 'meta', 'entities'], (t) => {
      t.objectStore('sealed').put(bytes, seq);
      const outbox = t.objectStore('outbox');
      for (const [k] of pending) outbox.delete(k);
      this.persist(t);
    });
  }

  /// Sealed segments → bucket, in seq order, write-once.
  flush(): Promise<number> {
    return locked(async () => {
      await this.fresh();
      if (this.fatal) return 0;
      await this.sealLocked();
      let sent = 0;
      for (const [seq, bytes] of await getAll<Uint8Array>(this.db, 'sealed')) {
        const r = await this.bucket.putOnce(segmentKey(this.device, seq as number), bytes);
        if (r === 'collision') {
          this.fatal = 'collision';
          await tx(this.db, ['meta', 'entities'], (t) => this.persist(t));
          break;
        }
        await tx(this.db, ['sealed'], (t) => t.objectStore('sealed').delete(seq));
        sent++;
      }
      return sent;
    });
  }

  async waiting(): Promise<number> {
    const sealed = await request(this.db.transaction('sealed', 'readonly').objectStore('sealed').count());
    return (await this.outboxSize()) + sealed;
  }

  /// First run: the newest checkpoint. Then: every device's segments past the cursor.
  pull(): Promise<number> {
    return locked(async () => {
      await this.fresh();
      await this.sealLocked();
      if (!this.hasCheckpoint) await this.loadCheckpoint();
      let applied = 0;
      const { prefixes } = await this.bucket.list('sync/log/', { delimiter: '/' });
      for (const prefix of prefixes) {
        const d = prefix.slice('sync/log/'.length, -1);
        if (d === this.device) continue;
        const have = this.state.vv[d] ?? 0;
        const { objects } = await this.bucket.list(prefix, have ? { startAfter: segmentKey(d, have) } : {});
        const next = objects
          .map((o) => ({ o, seq: seqOf(o.key) }))
          .filter((x): x is { o: ListedObject; seq: number } => x.seq !== null)
          .sort((a, b) => a.seq - b.seq);
        for (const { o, seq } of next) {
          if (seq !== (this.state.vv[d] ?? 0) + 1) break;
          let segment;
          try {
            segment = await decodeSegment(await this.bucket.get(o.key), o.lastModified);
          } catch (e) {
            if (e instanceof NewerProtocol) this.fatal = 'newer-protocol';
            break;
          }
          if (this.state.applySegment(segment)) applied++;
        }
      }
      if (applied > 0 || this.state.touched.size > 0) {
        await tx(this.db, ['entities', 'meta'], (t) => this.persist(t));
      }
      return applied;
    });
  }

  private async loadCheckpoint() {
    const { objects } = await this.bucket.list('sync/checkpoints/');
    const newest = objects
      .filter((o) => o.key.endsWith('.ndjson.gz'))
      .map((o) => ({ o, h: o.key.split('/').pop()!.replace('.ndjson.gz', '') }))
      .sort((a, b) => (a.h < b.h ? 1 : -1))[0];
    if (!newest) return;
    // Only ever adopted by an empty browser: edits wait for a checkpoint (see edit).
    this.state = await decodeCheckpoint(await this.bucket.get(newest.o.key));
    this.state.touched = new Set(this.state.entities.keys());
    this.hasCheckpoint = true;
  }

  /// For tests and the Sync panel.
  checkpointHeader() {
    return checkpointHeader(this.state, this.device, this.hlc);
  }
}

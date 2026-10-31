/// <reference types="node" />
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, test } from 'vitest';
import { decodeCheckpoint, encodeCheckpoint } from '../src/sync/checkpoint';
import { maxClockLeadMs, zero } from '../src/sync/hlc';
import { SyncState, members } from '../src/sync/merge';
import { type VersionVector, type WireOp, wall } from '../src/sync/op';
import { type Segment, decodeSegment, encodeSegment, withSegment } from '../src/sync/segment';

const dir = join(import.meta.dirname, '../../docs/design/cloud-sync/vectors');

interface Fixture {
  name: string;
  segments: { d: string; seq: number; vv: VersionVector; lastModified: number; ops: WireOp[] }[];
  expect: unknown;
}

function* interleavings(byDevice: Map<string, Segment[]>): Generator<Segment[]> {
  const live = [...byDevice].filter(([, l]) => l.length > 0);
  if (live.length === 0) return yield [];
  for (const [d, list] of live) {
    const rest = new Map(byDevice);
    rest.set(d, list.slice(1));
    for (const tail of interleavings(rest)) yield [list[0]!, ...tail];
  }
}

const view = (s: SyncState) => ({
  entities: Object.fromEntries(
    [...s.listed()].map((ent) => [
      `${ent.e}/${ent.id}`,
      {
        fields: Object.fromEntries([...ent.fields].map(([f, v]) => [f, v.x])),
        sets: Object.fromEntries(
          [...ent.sets.keys()].map((set) => [set, members(ent, set)]).filter(([, m]) => m!.length > 0),
        ),
      },
    ]),
  ),
  conflicts: s.conflicts().map(({ e, id, f, x, d }) => ({ e, id, f, x, d })),
});

const fixtures = readdirSync(dir)
  .filter((f) => f.endsWith('.json'))
  .sort()
  .map((f) => JSON.parse(readFileSync(join(dir, f), 'utf8')) as Fixture);

describe('protocol vectors', () => {
  test('fixtures exist', () => expect(fixtures.length).toBeGreaterThan(0));

  for (const fx of fixtures) {
    test(fx.name, async () => {
      const segments: Segment[] = fx.segments.map((s) => ({
        ...s,
        ops: s.ops.map((o) => withSegment(o, s.d, s.seq, s.vv)),
      }));
      const byDevice = new Map<string, Segment[]>();
      for (const s of segments) byDevice.set(s.d, [...(byDevice.get(s.d) ?? []), s]);
      let runs = 0;
      for (const order of interleavings(byDevice)) {
        const once = new SyncState();
        for (const s of order) once.applySegment(s);
        expect(view(once), order.map((s) => s.d + s.seq).join()).toEqual(fx.expect);

        const twice = new SyncState();
        for (const s of [...order, ...[...order].reverse()]) {
          twice.applySegment(s);
          for (const op of s.ops) if (wall(op) <= s.lastModified + maxClockLeadMs) twice.apply(op);
        }
        expect(view(twice), 'repeated').toEqual(fx.expect);

        for (let cut = 0; cut <= order.length; cut++) {
          let s = new SyncState();
          for (const seg of order.slice(0, cut)) s.applySegment(seg);
          s = await decodeCheckpoint(await encodeCheckpoint(s, 'z', zero));
          for (const seg of order.slice(cut)) s.applySegment(seg);
          expect(view(s), `checkpoint after ${cut}`).toEqual(fx.expect);
        }

        const decoded = new SyncState();
        for (const s of order) decoded.applySegment(await decodeSegment(await encodeSegment(s), s.lastModified));
        expect(view(decoded), 'segment codec').toEqual(fx.expect);
        runs++;
      }
      expect(runs).toBeGreaterThan(0);
    });
  }
});

/// <reference types="node" />
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { expect, test } from 'vitest';
import { SyncState, members } from '../src/sync/merge';
import { decodeSegment } from '../src/sync/segment';

// A segment the phone wrote (lib/sync/segment.dart), read here.
test('a phone segment reads back op for op', async () => {
  const bytes = readFileSync(join(import.meta.dirname, '../../docs/design/cloud-sync/vectors/wire/phone-000000000004.ndjson.gz'));
  const s = await decodeSegment(new Uint8Array(bytes), 1793414100000);
  expect([s.d, s.seq, s.vv]).toEqual(['phone', 4, { browser: 7 }]);
  expect(s.ops.map((o) => [o.e, o.id, o.o, o.f ?? null])).toEqual([
    ['asset', 'A/L0/001', 'set', 'location'],
    ['asset', 'A/L0/001', 'mrem', 'tags'],
    ['asset', 'A/L0/001', 'add', null],
    ['person', 'P', 'set', 'name'],
  ]);
  expect(s.ops[1]!.ts).toEqual(['1793414025000-0001@browser']);
  expect(s.ops[3]!.x).toBeNull();
  const state = new SyncState();
  state.vv.phone = 3;
  expect(state.applySegment(s)).toBe(true);
  const a = state.entities.get('asset/A/L0/001')!;
  expect(a.fields.get('description')?.x).toBe('海滩');
  expect(a.fields.get('is_favorite')?.x).toBe(1);
  expect(members(a, 'tags')).toEqual([]);
});

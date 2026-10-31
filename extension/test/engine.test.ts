import 'fake-indexeddb/auto';
import { expect, test } from 'vitest';
import { encodeCheckpoint } from '../src/sync/checkpoint';
import { Engine } from '../src/sync/engine';
import { format } from '../src/sync/hlc';
import { SyncState, members } from '../src/sync/merge';
import { FakeBucket } from './fake-bucket';

let n = 0;
const open = (bucket: FakeBucket) => Engine.open(bucket, { dbName: `t${n++}` });

/// What the phone's bootstrap would publish: one asset and one album.
const seed = async (bucket: FakeBucket) => {
  const s = new SyncState();
  const h = format({ wall: bucket.now(), counter: 0 });
  s.apply({ h, d: 'phone', seq: 1, vv: {}, e: 'asset', id: 'X', o: 'add', x: { description: 'orig' } });
  s.apply({ h: format({ wall: bucket.now(), counter: 0 }), d: 'phone', seq: 1, vv: {}, e: 'album', id: 'L', o: 'add', x: { name: 'Trip' } });
  s.vv.phone = 1;
  await bucket.put(`sync/checkpoints/phone/${h}.ndjson.gz`, await encodeCheckpoint(s, 'phone', { wall: 1, counter: 0 }));
};

const description = (e: Engine) => e.state.entities.get('asset/X')?.fields.get('description')?.x;

test('loads the checkpoint, edits converge, a concurrent edit becomes a conflict on both', async () => {
  const bucket = new FakeBucket();
  await seed(bucket);
  const a = await open(bucket);
  const b = await open(bucket);
  await a.pull();
  await b.pull();
  expect(description(a)).toBe('orig');

  await a.edit([{ e: 'asset', id: 'X', o: 'set', f: 'description', x: 'from a' }]);
  await b.edit([{ e: 'asset', id: 'X', o: 'set', f: 'description', x: 'from b' }]);
  await b.edit([{ e: 'album', id: 'L', o: 'madd', f: 'members', x: 'X' }]);
  await a.flush();
  await b.flush();
  await a.pull();
  await b.pull();

  expect(description(a)).toBe(description(b));
  expect(a.state.conflicts().map((c) => c.x)).toEqual(b.state.conflicts().map((c) => c.x));
  expect(a.state.conflicts()).toHaveLength(1);
  expect(members(a.state.entities.get('album/L')!, 'members')).toEqual(['X']);

  // Resolving on a supersedes both heads everywhere.
  await a.edit([{ e: 'asset', id: 'X', o: 'set', f: 'description', x: 'resolved' }]);
  await a.flush();
  await b.pull();
  expect(b.state.conflicts()).toHaveLength(0);
  expect(description(b)).toBe('resolved');
});

test('a PUT that landed but whose answer was lost is not sent twice or lost', async () => {
  const bucket = new FakeBucket();
  await seed(bucket);
  const a = await open(bucket);
  await a.pull();
  await a.edit([{ e: 'asset', id: 'X', o: 'set', f: 'is_favorite', x: 1 }]);
  bucket.failNextPutAfterWrite = true;
  await expect(a.flush()).rejects.toThrow();
  expect(await a.waiting()).toBe(1);
  expect(await a.flush()).toBe(1);
  expect(await a.waiting()).toBe(0);

  const b = await open(bucket);
  await b.pull();
  expect(b.state.entities.get('asset/X')?.fields.get('is_favorite')?.x).toBe(1);
});

test('edits survive a reload before they are flushed', async () => {
  const bucket = new FakeBucket();
  await seed(bucket);
  const name = `t${n++}`;
  const a = await Engine.open(bucket, { dbName: name });
  await a.pull();
  await a.edit([{ e: 'asset', id: 'X', o: 'madd', f: 'tags', x: 'beach' }]);
  const again = await Engine.open(bucket, { dbName: name });
  expect(members(again.state.entities.get('asset/X')!, 'tags')).toEqual(['beach']);
  expect(await again.flush()).toBe(1);
});

test('another writer at our key stops writing instead of overwriting', async () => {
  const bucket = new FakeBucket();
  await seed(bucket);
  const a = await open(bucket);
  await a.pull();
  await bucket.put(`sync/log/${a.device}/000000000001.ndjson.gz`, new Uint8Array([1, 2, 3]));
  await a.edit([{ e: 'asset', id: 'X', o: 'set', f: 'is_favorite', x: 1 }]);
  expect(await a.flush()).toBe(0);
  expect(a.fatal).toBe('collision');
  expect(await a.waiting()).toBe(1);
});

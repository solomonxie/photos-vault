import { expect, test } from 'vitest';
import { SearchIndex, buildLibrary, groupByDay } from '../src/model';
import { parsePaste, originsFor } from '../src/connection';
import { SyncState } from '../src/sync/merge';
import type { WireOp } from '../src/sync/op';

let n = 0;
const state = (ops: Omit<WireOp, 'h'>[]) => {
  const s = new SyncState();
  for (const o of ops) s.apply({ ...o, h: `${String(1793414025000 + n++).padStart(13, '0')}-0000`, d: 'p', seq: 1, vv: {} });
  return s;
};
const day = (d: number) => new Date(2026, 9, d, 12).getTime();

test('timeline, bin, hidden and purged; albums and people only over photos still here', () => {
  const lib = buildLibrary(
    state([
      { e: 'asset', id: 'A', o: 'add', x: { created_at: day(28), location: 'Lisbon, Portugal', description: 'Tram' } },
      { e: 'asset', id: 'B', o: 'add', x: { created_at: day(29), location: 'Cascais, Portugal', deleted_at: day(30) } },
      { e: 'asset', id: 'C', o: 'add', x: { created_at: day(27), hidden: true } },
      { e: 'asset', id: 'D', o: 'add', x: { created_at: day(26), purged: day(30) } },
      { e: 'album', id: 'L', o: 'add', x: { name: 'Trip' } },
      { e: 'album', id: 'L', o: 'madd', f: 'members', x: 'A' },
      { e: 'album', id: 'L', o: 'madd', f: 'members', x: 'C' },
      { e: 'person', id: 'P', o: 'add', x: { name: '' } },
    ]),
  );
  expect(lib.timeline.map((p) => p.id)).toEqual(['A']);
  expect(lib.bin.map((p) => p.id)).toEqual(['B']);
  expect(lib.albums[0]!.photos).toEqual(['A']);
  expect(lib.people).toEqual([]);
});

test('places: country and city from the photos, hand-made pins under their city with descriptions', () => {
  const lib = buildLibrary(
    state([
      { e: 'asset', id: 'A', o: 'add', x: { created_at: day(1), location: 'Lisbon, Portugal' } },
      { e: 'asset', id: 'B', o: 'add', x: { created_at: day(2), location: 'Lisbon, Portugal' } },
      { e: 'asset', id: 'C', o: 'add', x: { created_at: day(3), location: 'Portugal' } },
      { e: 'place', id: 'pin1', o: 'add', x: { name: 'Alfama', description: 'Old town', city: 'Lisbon', country: 'Portugal', lat: 38.71, lng: -9.13 } },
      { e: 'place', id: 'pin1', o: 'madd', f: 'photos', x: 'A' },
    ]),
  );
  const pt = lib.places[0]!;
  expect([pt.level, pt.name, pt.photos.length]).toEqual(['country', 'Portugal', 3]);
  const lisbon = pt.children[0]!;
  expect([lisbon.level, lisbon.name, lisbon.photos.length]).toEqual(['city', 'Lisbon', 2]);
  expect(lisbon.children.map((c) => [c.level, c.name, c.description, c.photos])).toEqual([['pin', 'Alfama', 'Old town', ['A']]]);
});

test('days group by local date; search finds places, albums and captions', () => {
  const lib = buildLibrary(
    state([
      { e: 'asset', id: 'A', o: 'add', x: { created_at: day(28) + 1000, location: 'Lisbon, Portugal' } },
      { e: 'asset', id: 'B', o: 'add', x: { created_at: day(28), description: 'lisbon tram' } },
      { e: 'asset', id: 'C', o: 'add', x: { created_at: day(20) } },
      { e: 'album', id: 'L', o: 'add', x: { name: 'Lisbon 2026' } },
      { e: 'album', id: 'L', o: 'madd', f: 'members', x: 'C' },
    ]),
  );
  expect(groupByDay(lib.timeline).map((d) => [d.photos.length, d.place])).toEqual([[2, 'Lisbon'], [1, '']]);
  const s = new SearchIndex(lib);
  expect(s.suggest('lisb').map((h) => h.kind)).toEqual(['place', 'album', 'caption']);
  expect(s.all('lisb')).toEqual(['A', 'B', 'C']);
});

test('a pasted note fills the fields, a base64 secret intact', () => {
  expect(
    parsePaste('export AWS_ACCESS_KEY_ID="AKIA123"\nsecret_access_key: ab/c+d==\nBucket = my-photos,\nprefix: vault/\nfoo: bar\nregion:'),
  ).toEqual({ accessKeyId: 'AKIA123', secretAccessKey: 'ab/c+d==', bucket: 'my-photos', prefix: 'vault/' });
});

test('host access asks for this one bucket, not the whole provider', () => {
  expect(originsFor({ provider: 's3', bucket: 'my-vault', region: 'ca-central-1' })).toEqual([
    'https://my-vault.s3.amazonaws.com/*',
    'https://my-vault.s3.ca-central-1.amazonaws.com/*',
  ]);
  expect(originsFor({ provider: 's3', bucket: 'my-vault', region: '' })).toEqual(['https://my-vault.s3.amazonaws.com/*']);
  expect(originsFor({ provider: 'cos', bucket: 'b-1250000000', region: 'ap-hongkong' })).toEqual([
    'https://b-1250000000.cos.ap-hongkong.myqcloud.com/*',
  ]);
});

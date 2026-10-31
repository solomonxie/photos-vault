import { type Hlc, format, parse, receive } from './hlc';
import { gunzipLines, gzipLines } from './gzip';
import { type EntityState, SyncState } from './merge';
import type { Scalar, VersionVector } from './op';
import { NewerProtocol, protocolVersion } from './segment';

/// The whole merge state as one file: `sync/checkpoints/<d>/<hlc>.ndjson.gz`.
/// Same line format as lib/sync/checkpoint.dart.
export const checkpointKey = (d: string, h: Hlc) => `sync/checkpoints/${d}/${format(h)}.ndjson.gz`;

interface Line {
  e: string;
  id: string;
  exists: boolean;
  f: Record<string, { x: Scalar; s: string }>;
  heads: Record<string, { x: Scalar; s: string; seq: number; vv: VersionVector }[]>;
  sets: Record<string, Record<string, { a: string[]; r: string[] }>>;
}

export const entityLine = (ent: EntityState): string => {
  const line: Line = {
    e: ent.e,
    id: ent.id,
    exists: ent.exists,
    f: Object.fromEntries([...ent.fields].map(([f, v]) => [f, { x: v.x, s: v.s }])),
    heads: Object.fromEntries(
      [...ent.heads].map(([f, ops]) => [
        f,
        ops.map((op) => ({ x: (op.x ?? null) as Scalar, s: `${op.h}@${op.d}`, seq: op.seq, vv: op.vv })),
      ]),
    ),
    sets: Object.fromEntries(
      [...ent.sets].map(([set, m]) => [
        set,
        Object.fromEntries([...m].map(([member, t]) => [member, { a: [...t.a], r: [...t.r] }])),
      ]),
    ),
  };
  return JSON.stringify(line);
};

export const checkpointHeader = (s: SyncState, d: string, h: Hlc) =>
  JSON.stringify({ v: protocolVersion, d, h: format(h), vv: s.vv });

export function* checkpointLines(s: SyncState, d: string, h: Hlc): Iterable<string> {
  yield checkpointHeader(s, d, h);
  for (const ent of s.entities.values()) yield entityLine(ent);
}

export const encodeCheckpoint = (s: SyncState, d: string, h: Hlc) => gzipLines(checkpointLines(s, d, h));

export const decodeCheckpointLines = (lines: string[]): SyncState => {
  const head = JSON.parse(lines[0] ?? '{}') as { v: number; vv: VersionVector };
  if (head.v > protocolVersion) throw new NewerProtocol(head.v);
  const s = new SyncState();
  s.vv = { ...head.vv };
  for (const raw of lines.slice(1)) {
    const j = JSON.parse(raw) as Line;
    const ent = s.entity(j.e, j.id);
    ent.exists = j.exists;
    for (const [f, v] of Object.entries(j.f)) {
      ent.fields.set(f, v);
      s.seen = receive(s.seen, parse(v.s.split('@')[0]!));
    }
    for (const [f, heads] of Object.entries(j.heads)) {
      ent.heads.set(
        f,
        heads.map((h) => {
          const [hlc, d] = h.s.split('@') as [string, string];
          return { h: hlc, d, seq: h.seq, vv: h.vv, e: j.e, id: j.id, o: 'set' as const, f, x: h.x };
        }),
      );
    }
    for (const [set, m] of Object.entries(j.sets)) {
      const target = new Map<string, { a: Set<string>; r: Set<string> }>();
      for (const [member, t] of Object.entries(m)) target.set(member, { a: new Set(t.a), r: new Set(t.r) });
      ent.sets.set(set, target);
    }
  }
  return s;
};

export const decodeCheckpoint = async (bytes: Uint8Array) => decodeCheckpointLines(await gunzipLines(bytes));

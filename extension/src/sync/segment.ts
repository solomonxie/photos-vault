import { gunzipLines, gzipLines } from './gzip';
import { type Op, type VersionVector, type WireOp, toWire } from './op';

export const protocolVersion = 1;
export const segmentMaxOps = 200;

/// One immutable file of one device's ops: `sync/log/<d>/<seq:012d>.ndjson.gz`.
export interface Segment {
  d: string;
  seq: number;
  vv: VersionVector;
  ops: Op[];
  /// Server time the object landed; 0 until read back from the bucket.
  lastModified: number;
}

/// Written by a newer app: stop writing, keep reading what we can.
export class NewerProtocol extends Error {
  constructor(readonly v: number) {
    super(`sync protocol ${v} is newer than ${protocolVersion}`);
  }
}

export const segmentKey = (d: string, seq: number) =>
  `sync/log/${d}/${String(seq).padStart(12, '0')}.ndjson.gz`;

export const seqOf = (key: string): number | null => {
  const m = /\/(\d{12})\.ndjson\.gz$/.exec(key);
  return m ? Number(m[1]) : null;
};

export const withSegment = (w: WireOp, d: string, seq: number, vv: VersionVector): Op => ({
  ...w,
  d,
  seq,
  vv,
});

export const encodeSegment = (s: Segment) =>
  gzipLines([
    JSON.stringify({ v: protocolVersion, d: s.d, seq: s.seq, vv: s.vv, n: s.ops.length }),
    ...s.ops.map((op) => JSON.stringify(toWire(op))),
  ]);

export const decodeSegment = async (bytes: Uint8Array, lastModified: number): Promise<Segment> => {
  const lines = await gunzipLines(bytes);
  const head = JSON.parse(lines[0] ?? '{}') as { v: number; d: string; seq: number; vv: VersionVector; n: number };
  if (head.v > protocolVersion) throw new NewerProtocol(head.v);
  const ops = lines.slice(1).map((l) => withSegment(JSON.parse(l) as WireOp, head.d, head.seq, head.vv));
  if (ops.length !== head.n) throw new Error(`segment ${head.d}/${head.seq}: ${ops.length} of ${head.n} ops`);
  return { d: head.d, seq: head.seq, vv: head.vv, ops, lastModified };
};

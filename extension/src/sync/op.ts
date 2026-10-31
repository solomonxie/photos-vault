import { parse } from './hlc';

export type OpKind = 'add' | 'set' | 'madd' | 'mrem';
export type Scalar = string | number | boolean | null;
export type VersionVector = Record<string, number>;

/// One change to one entity, as written on the wire (`d`, `seq`, `vv` come from the segment).
export interface WireOp {
  h: string;
  e: string;
  id: string;
  o: OpKind;
  f?: string;
  x?: Scalar | Record<string, Scalar>;
  ts?: string[];
}

export interface Op extends WireOp {
  d: string;
  seq: number;
  vv: VersionVector;
}

export const stamp = (op: Pick<Op, 'h' | 'd'>): string => `${op.h}@${op.d}`;
export const wall = (op: Pick<Op, 'h'>): number => parse(op.h).wall;

/// Whether `a` was made knowing `b`. Seen implies a greater stamp.
export const saw = (a: Op, b: Op): boolean =>
  a.d === b.d ? stamp(a) > stamp(b) : (a.vv[b.d] ?? 0) >= b.seq;

export const textFields: Record<string, ReadonlySet<string>> = {
  asset: new Set(['description', 'location']),
  album: new Set(['name', 'description']),
  person: new Set(['name', 'bio']),
};

export const toWire = (op: Op): WireOp => {
  const w: WireOp = { h: op.h, e: op.e, id: op.id, o: op.o };
  if (op.f !== undefined) w.f = op.f;
  if (op.o !== 'add' || op.x != null) w.x = op.x ?? null;
  if (op.o === 'mrem') w.ts = op.ts ?? [];
  return w;
};

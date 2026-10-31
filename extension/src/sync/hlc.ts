// Hybrid logical clock, `<wall:013d>-<counter:04d>`. See PROTOCOL.md.

export interface Hlc {
  wall: number;
  counter: number;
}

export const zero: Hlc = { wall: 0, counter: 0 };

/// Ops stamped further than this past their segment's LastModified are ignored.
export const maxClockLeadMs = 3_600_000;

export const parse = (s: string): Hlc => {
  const dash = s.indexOf('-');
  return { wall: Number(s.slice(0, dash)), counter: Number(s.slice(dash + 1)) };
};

export const format = (h: Hlc): string =>
  `${String(h.wall).padStart(13, '0')}-${String(h.counter).padStart(4, '0')}`;

export const compare = (a: Hlc, b: Hlc): number =>
  a.wall !== b.wall ? a.wall - b.wall : a.counter - b.counter;

export const tick = (last: Hlc, now: number): Hlc =>
  now > last.wall ? { wall: now, counter: 0 } : { wall: last.wall, counter: last.counter + 1 };

export const receive = (last: Hlc, seen: Hlc): Hlc => (compare(last, seen) >= 0 ? last : seen);

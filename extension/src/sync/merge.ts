import { type Hlc, maxClockLeadMs, parse, receive, zero } from './hlc';
import { type Op, type Scalar, type VersionVector, saw, stamp, textFields, wall } from './op';
import type { Segment } from './segment';

export interface Stamped {
  x: Scalar;
  s: string;
}

export interface OrSetEntry {
  a: Set<string>;
  r: Set<string>;
}

export interface EntityState {
  e: string;
  id: string;
  exists: boolean;
  fields: Map<string, Stamped>;
  /// Per text field, the ops no other op on that field has seen.
  heads: Map<string, Op[]>;
  sets: Map<string, Map<string, OrSetEntry>>;
}

export interface Conflict {
  e: string;
  id: string;
  f: string;
  x: Scalar;
  d: string;
  s: string;
}

export const members = (ent: EntityState, set: string): string[] =>
  [...(ent.sets.get(set) ?? new Map<string, OrSetEntry>())]
    .filter(([, t]) => [...t.a].some((tag) => !t.r.has(tag)))
    .map(([m]) => m)
    .sort();

/// The merged library: same result from the same ops in any order.
/// Mirrors lib/sync/merge.dart; both run docs/design/cloud-sync/vectors.
export class SyncState {
  entities = new Map<string, EntityState>();
  vv: VersionVector = {};
  seen: Hlc = zero;
  /// Keys of entities changed since the caller last cleared it: what to persist.
  touched = new Set<string>();

  entity(e: string, id: string): EntityState {
    const key = `${e}/${id}`;
    this.touched.add(key);
    let ent = this.entities.get(key);
    if (!ent) {
      ent = { e, id, exists: false, fields: new Map(), heads: new Map(), sets: new Map() };
      this.entities.set(key, ent);
    }
    return ent;
  }

  /// Applies `s` if it is the device's next; false on a gap or a repeat.
  applySegment(s: Segment): boolean {
    if (s.seq !== (this.vv[s.d] ?? 0) + 1) return false;
    const bound = s.lastModified + maxClockLeadMs;
    for (const op of s.ops) if (wall(op) <= bound) this.apply(op);
    this.vv[s.d] = s.seq;
    return true;
  }

  apply(op: Op): void {
    this.seen = receive(this.seen, parse(op.h));
    const ent = this.entity(op.e, op.id);
    switch (op.o) {
      case 'add': {
        ent.exists = true;
        const x = (op.x ?? {}) as Record<string, Scalar>;
        for (const f of Object.keys(x)) this.setField(ent, f, x[f] ?? null, op);
        break;
      }
      case 'set':
        this.setField(ent, op.f!, (op.x ?? null) as Scalar, op);
        break;
      case 'madd':
        this.entry(ent, op).a.add(stamp(op));
        break;
      case 'mrem':
        for (const t of op.ts ?? []) this.entry(ent, op).r.add(t);
        break;
    }
  }

  private entry(ent: EntityState, op: Op): OrSetEntry {
    let set = ent.sets.get(op.f!);
    if (!set) ent.sets.set(op.f!, (set = new Map()));
    let entry = set.get(op.x as string);
    if (!entry) set.set(op.x as string, (entry = { a: new Set(), r: new Set() }));
    return entry;
  }

  private setField(ent: EntityState, f: string, x: Scalar, op: Op): void {
    const s = stamp(op);
    const cur = ent.fields.get(f);
    if (!cur || s > cur.s) ent.fields.set(f, { x, s });
    if (!textFields[ent.e]?.has(f)) return;
    const asField: Op = op.o === 'set' ? op : { ...op, o: 'set', f, x };
    const heads = ent.heads.get(f) ?? [];
    if (heads.some((h) => stamp(h) === s || saw(h, asField))) return;
    ent.heads.set(f, [...heads.filter((h) => !saw(asField, h)), asField]);
  }

  *listed(): Iterable<EntityState> {
    for (const ent of this.entities.values()) if (ent.exists) yield ent;
  }

  conflicts(): Conflict[] {
    const out: Conflict[] = [];
    for (const ent of this.listed()) {
      for (const [f, heads] of ent.heads) {
        const winner = ent.fields.get(f)!.s;
        for (const h of heads) {
          const s = stamp(h);
          if (s !== winner) out.push({ e: ent.e, id: ent.id, f, x: (h.x ?? null) as Scalar, d: h.d, s });
        }
      }
    }
    const key = (c: Conflict) => [c.e, c.id, c.f, c.s];
    return out.sort((a, b) => {
      const ka = key(a);
      const kb = key(b);
      for (let i = 0; i < ka.length; i++) if (ka[i] !== kb[i]) return ka[i]! < kb[i]! ? -1 : 1;
      return 0;
    });
  }
}

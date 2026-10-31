import { type EntityState, type SyncState, members } from './sync/merge';
import type { Scalar } from './sync/op';

export interface Photo {
  id: string;
  takenAt: number;
  description: string;
  location: string;
  isVideo: boolean;
  isLive: boolean;
  favorite: boolean;
  width: number;
  height: number;
  thumbKey: string | null;
  mediumKey: string | null;
  originalKey: string | null;
  editedKey: string | null;
  tags: string[];
  binnedAt: number | null;
}

export interface Album {
  id: string;
  name: string;
  description: string;
  cover: string | null;
  photos: string[];
}

export interface Person {
  id: string;
  name: string;
  avatar: string | null;
  photos: string[];
}

export type PlaceLevel = 'country' | 'city' | 'pin';

export interface Place {
  level: PlaceLevel;
  name: string;
  /// A pin's spot, and what its maker wrote about it.
  at?: { lat: number; lng: number };
  description?: string;
  photos: string[];
  children: Place[];
}

export interface Day {
  key: string;
  at: number;
  place: string;
  photos: Photo[];
}

/// Everything the screens draw, derived once per pull — never per render.
export interface Library {
  photos: Map<string, Photo>;
  /// Newest first, not binned.
  timeline: Photo[];
  bin: Photo[];
  albums: Album[];
  people: Person[];
  places: Place[];
  albumsOf: Map<string, string[]>;
  peopleOf: Map<string, string[]>;
}

const str = (v: Scalar | undefined) => (typeof v === 'string' ? v : '');
const num = (v: Scalar | undefined) => (typeof v === 'number' ? v : 0);
const flag = (v: Scalar | undefined) => v === 1 || v === true;
const key = (v: Scalar | undefined) => (typeof v === 'string' && v.length > 0 ? v : null);

const field = (ent: EntityState, f: string) => ent.fields.get(f)?.x;

const gone = (ent: EntityState) => flag(field(ent, 'hidden')) || field(ent, 'purged') != null;

export function photoOf(ent: EntityState): Photo {
  const binned = field(ent, 'deleted_at');
  return {
    id: ent.id,
    takenAt: num(field(ent, 'created_at')),
    description: str(field(ent, 'description')),
    location: str(field(ent, 'location')),
    isVideo: flag(field(ent, 'is_video')),
    isLive: flag(field(ent, 'is_live_photo')),
    favorite: flag(field(ent, 'is_favorite')),
    width: num(field(ent, 'width')),
    height: num(field(ent, 'height')),
    thumbKey: key(field(ent, 'thumbnail_key')),
    mediumKey: key(field(ent, 'medium_key')),
    originalKey: key(field(ent, 'original_key')),
    editedKey: key(field(ent, 'edited_key')),
    tags: members(ent, 'tags'),
    binnedAt: typeof binned === 'number' ? binned : null,
  };
}

/// The phone names a place "City, Country": country and city are automatic.
const cityOf = (location: string): [string, string] | null => {
  const parts = location
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (parts.length === 0) return null;
  const country = parts[parts.length - 1]!;
  return [country, parts.length > 1 ? parts[parts.length - 2]! : ''];
};

/// A hand-made pin from the phone's Footprints (`place` entities), filed
/// under its city by name. An area made on the phone is shown as a pin too.
export interface HandPlace {
  id: string;
  name: string;
  description: string;
  country: string;
  city: string;
  at?: { lat: number; lng: number };
  photos: string[];
}

/// Every place, as one tree: country → city from the photos' own location
/// names; pins under their city, made by hand.
export function buildPlaces(photos: Photo[], hand: HandPlace[] = []): Place[] {
  const countries: Place[] = [];
  const node = (list: Place[], level: PlaceLevel, name: string) => {
    let n = list.find((c) => c.level === level && c.name === name);
    if (!n) list.push((n = { level, name, photos: [], children: [] }));
    return n;
  };
  for (const p of photos) {
    const at = cityOf(p.location);
    if (!at) continue;
    const country = node(countries, 'country', at[0]);
    country.photos.push(p.id);
    if (at[1]) node(country.children, 'city', at[1]).photos.push(p.id);
  }
  for (const hp of hand) {
    const country = node(countries, 'country', hp.country);
    const parent = hp.city ? node(country.children, 'city', hp.city) : country;
    parent.children.push({
      level: 'pin',
      name: hp.name,
      at: hp.at,
      description: hp.description,
      photos: hp.photos,
      children: [],
    });
  }
  const sort = (list: Place[]) => {
    list.sort((a, b) => b.photos.length - a.photos.length || a.name.localeCompare(b.name));
    for (const c of list) sort(c.children);
  };
  sort(countries);
  return countries;
}

export function buildLibrary(state: SyncState): Library {
  const photos = new Map<string, Photo>();
  const albums: Album[] = [];
  const people: Person[] = [];
  for (const ent of state.listed()) {
    if (ent.e === 'asset' && !gone(ent)) photos.set(ent.id, photoOf(ent));
  }
  const albumsOf = new Map<string, string[]>();
  const peopleOf = new Map<string, string[]>();
  const live = (ids: string[]) => ids.filter((id) => photos.has(id));
  const hand: HandPlace[] = [];
  for (const ent of state.listed()) {
    if (gone(ent) || field(ent, 'deleted_at') != null) continue;
    if (ent.e === 'place') {
      const lat = field(ent, 'lat');
      const lng = field(ent, 'lng');
      hand.push({
        id: ent.id,
        name: str(field(ent, 'name')),
        description: str(field(ent, 'description')),
        country: str(field(ent, 'country')),
        city: str(field(ent, 'city')),
        at: typeof lat === 'number' && typeof lng === 'number' ? { lat, lng } : undefined,
        photos: members(ent, 'photos').filter((id) => photos.has(id)),
      });
    } else if (ent.e === 'album') {
      const ids = live(members(ent, 'members'));
      albums.push({
        id: ent.id,
        name: str(field(ent, 'name')),
        description: str(field(ent, 'description')),
        cover: key(field(ent, 'cover_local_id')),
        photos: ids,
      });
      for (const id of ids) albumsOf.set(id, [...(albumsOf.get(id) ?? []), ent.id]);
    } else if (ent.e === 'person') {
      const name = str(field(ent, 'name'));
      if (!name) continue;
      const ids = live(members(ent, 'members'));
      people.push({ id: ent.id, name, avatar: key(field(ent, 'avatar_local_id')), photos: ids });
      for (const id of ids) peopleOf.set(id, [...(peopleOf.get(id) ?? []), ent.id]);
    }
  }
  const all = [...photos.values()].sort((a, b) => b.takenAt - a.takenAt);
  const timeline = all.filter((p) => p.binnedAt === null);
  const byTaken = (ids: string[]) =>
    ids.sort((a, b) => (photos.get(b)?.takenAt ?? 0) - (photos.get(a)?.takenAt ?? 0));
  for (const a of albums) byTaken(a.photos);
  for (const p of people) byTaken(p.photos);
  albums.sort((a, b) => (photos.get(b.photos[0] ?? '')?.takenAt ?? 0) - (photos.get(a.photos[0] ?? '')?.takenAt ?? 0));
  people.sort((a, b) => b.photos.length - a.photos.length || a.name.localeCompare(b.name));
  return {
    photos,
    timeline,
    bin: all.filter((p) => p.binnedAt !== null).sort((a, b) => (b.binnedAt ?? 0) - (a.binnedAt ?? 0)),
    albums,
    people,
    places: buildPlaces(timeline, hand),
    albumsOf,
    peopleOf,
  };
}

const dayKey = (t: number) => {
  const d = new Date(t);
  return `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
};

/// Photos (already newest first) grouped by local calendar day, each day
/// named by its most common place.
export function groupByDay(photos: Photo[]): Day[] {
  const days: Day[] = [];
  for (const p of photos) {
    const k = dayKey(p.takenAt);
    const last = days[days.length - 1];
    if (last && last.key === k) last.photos.push(p);
    else days.push({ key: k, at: p.takenAt, place: '', photos: [p] });
  }
  for (const d of days) {
    const counts = new Map<string, number>();
    for (const p of d.photos) {
      const city = p.location.split(',')[0]?.trim();
      if (city) counts.set(city, (counts.get(city) ?? 0) + 1);
    }
    d.place = [...counts].sort((a, b) => b[1] - a[1])[0]?.[0] ?? '';
  }
  return days;
}

export interface SearchHit {
  kind: 'place' | 'person' | 'album' | 'caption';
  label: string;
  photos: string[];
}

/// Built once per library; a query is a pass over names, not over IndexedDB.
export class SearchIndex {
  private captions: { id: string; text: string }[];

  constructor(private lib: Library) {
    this.captions = lib.timeline.map((p) => ({
      id: p.id,
      text: `${p.description} ${p.tags.join(' ')} ${p.location}`.toLowerCase(),
    }));
  }

  suggest(query: string, limit = 4): SearchHit[] {
    const q = query.trim().toLowerCase();
    if (!q) return [];
    const hits: SearchHit[] = [];
    const flat = (list: Place[], out: Place[] = []) => {
      for (const p of list) {
        out.push(p);
        flat(p.children, out);
      }
      return out;
    };
    const named = flat(this.lib.places).filter((p) => p.level !== 'pin');
    for (const p of named.filter((p) => p.name.toLowerCase().includes(q)).slice(0, limit)) {
      hits.push({ kind: 'place', label: p.name, photos: p.photos });
    }
    for (const p of this.lib.people.filter((p) => p.name.toLowerCase().includes(q)).slice(0, limit)) {
      hits.push({ kind: 'person', label: p.name, photos: p.photos });
    }
    for (const a of this.lib.albums.filter((a) => a.name.toLowerCase().includes(q)).slice(0, limit)) {
      hits.push({ kind: 'album', label: a.name, photos: a.photos });
    }
    const captions = this.captions.filter((c) => c.text.includes(q)).map((c) => c.id);
    if (captions.length > 0) hits.push({ kind: 'caption', label: query.trim(), photos: captions });
    return hits;
  }

  /// Every photo any suggestion names, newest first.
  all(query: string): string[] {
    const ids = new Set(this.suggest(query, Infinity).flatMap((h) => h.photos));
    return this.lib.timeline.filter((p) => ids.has(p.id)).map((p) => p.id);
  }
}

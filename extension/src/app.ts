import { Bucket, type Connection } from './bucket/client';
import { forgetConnection, loadConnection } from './connection';
import { type Impression, type Library, type Photo, type Place, type Plan, SearchIndex, buildLibrary, placeIds } from './model';
import { Engine } from './sync/engine';
import type { Conflict } from './sync/merge';
import { clear, h } from './ui/dom';
import { Editor, askText, confirmDanger, pickOrCreate, toast } from './ui/edits';
import { type Selection, dayGrid } from './ui/grid';
import { type IconName, icon } from './ui/icons';
import { ago, count, t } from './ui/i18n';
import { settingsView } from './ui/settings';
import { setupView, waitingView } from './ui/setup';
import { purgeMediaCache, thumbUrl } from './ui/thumbs';
import { openViewer, viewerRefresh } from './ui/viewer';
import { dropZone, pickFiles, uploadTray } from './upload/tray';
import { Uploader } from './upload/uploader';

const root = document.getElementById('app')!;
const pullEvery = 30_000;

let bucket: Bucket;
let engine: Engine;
let editor: Editor;
let uploader: Uploader;
let tray: ReturnType<typeof uploadTray>;
let lib: Library;
let search: SearchIndex;
let lastSynced = 0;
let waiting = 0;
let syncState: 'ok' | 'busy' | 'offline' | 'error' = 'busy';
let syncError = '';
let disposeGrid: (() => void) | null = null;
let currentRoute = '';
let live = false;
let pullTimer = 0;
let refreshSettings: (() => void) | null = null;
const selection: Selection = { ids: new Set(), changed: () => renderSelectionBar() };

const chip = h('button', { class: 'status' });
const syncButton = h('button', { class: 'icon-btn', title: t('syncNow'), 'aria-label': t('syncNow') }, icon('sync'));
const main = h('main', { class: 'content' });
const selectionBar = h('div', { class: 'selection-bar', hidden: true });

const conflictsOf = (e: string, id: string): Conflict[] => {
  const ent = engine.state.entities.get(`${e}/${id}`);
  if (!ent) return [];
  return engine.state.conflicts().filter((c) => c.e === e && c.id === id);
};

function renderChip() {
  const conflicts = engine ? engine.state.conflicts().length : 0;
  const [name, text, tone]: [IconName, string, string] =
    syncState === 'busy'
      ? ['sync', t('statusSyncing'), 'busy']
      : syncState === 'offline'
        ? ['cloud', t('statusOffline'), 'offline']
        : syncState === 'error'
          ? ['alert', t('statusError'), 'error']
          : conflicts > 0
            ? ['alert', t('statusConflicts', count(conflicts)), 'error']
            : waiting > 0
              ? ['upload', t('statusWaiting', count(waiting)), 'ok']
              : ['check', lastSynced ? t('statusSyncedAgo', ago(lastSynced)) : t('statusSynced'), 'ok'];
  chip.className = `status ${tone}`;
  chip.replaceChildren(icon(name, { size: 16 }), h('span', {}, text));
  syncButton.classList.toggle('spinning', syncState === 'busy');
  refreshSettings?.();
}

/// After a local edit or a pull that moved something: the library is
/// derived again and the page redrawn where it was.
let rebuildFrame = 0;
function rebuild() {
  if (rebuildFrame) return;
  rebuildFrame = requestAnimationFrame(() => {
    rebuildFrame = 0;
    lib = buildLibrary(engine.state);
    search = new SearchIndex(lib);
    const top = main.scrollTop;
    route(true);
    main.scrollTop = top;
    viewerRefresh?.();
    void engine.waiting().then((n) => {
      waiting = n;
      renderChip();
    });
  });
}

async function pull() {
  if (!live) return;
  if (!navigator.onLine) {
    syncState = 'offline';
    renderChip();
    return;
  }
  syncState = 'busy';
  renderChip();
  try {
    await editor?.send();
    const applied = await engine.pull();
    lastSynced = Date.now();
    syncState = engine.fatal ? 'error' : 'ok';
    syncError = engine.fatal ? t(engine.fatal === 'newer-protocol' ? 'statusNewer' : 'statusCollision') : '';
    if (applied > 0 || !lib) rebuild();
  } catch (e) {
    syncState = navigator.onLine ? 'error' : 'offline';
    syncError = String(e instanceof Error ? e.message : e);
  }
  waiting = await engine.waiting();
  renderChip();
}

// ------------------------------------------------------------ sync panel

function syncPanel() {
  document.querySelector('.sync-panel')?.remove();
  const conflicts = engine.state.conflicts();
  const open = (c: Conflict) => {
    panel.remove();
    if (c.e === 'asset') {
      const p = lib.photos.get(c.id);
      if (p) openViewer(viewerContext(), p, [p]);
    } else {
      location.hash = `#/${c.e}/${c.id}`;
    }
  };
  const label = (c: Conflict) =>
    c.e === 'asset'
      ? `${t('conflictPhoto')} · ${t(c.f === 'location' ? 'viewerLocation' : 'conflictField_description')}`
      : `${(c.e === 'album' ? lib.albums : lib.people).find((x) => x.id === c.id)?.name ?? '—'} · ${t(`conflictField_${c.f}`)}`;
  const panel = h(
    'div',
    { class: 'sync-panel' },
    h('div', { class: 'muted' }, `${bucket.c.bucket}/${bucket.c.prefix}`),
    h('div', {}, lastSynced ? t('statusLast', ago(lastSynced)) : t('statusNever')),
    h('div', {}, t('panelWaiting', count(waiting))),
    syncError ? h('div', { class: 'error' }, syncError) : null,
    conflicts.length ? h('div', { class: 'section-title' }, t('panelConflicts', count(conflicts.length))) : null,
    ...conflicts.map((c) => h('button', { class: 'panel-row', onclick: () => open(c) }, h('span', {}, label(c)), h('span', { class: 'muted' }, '›'))),
    h(
      'div',
      { class: 'panel-actions' },
      h('button', { class: 'link', onclick: () => void pull() }, t('syncNow')),
      h('a', { class: 'link', href: '#/settings', onclick: () => panel.remove() }, t('navSettings')),
    ),
  );
  const at = chip.getBoundingClientRect();
  panel.style.top = `${Math.round(at.bottom + 8)}px`;
  panel.style.right = `${Math.max(16, Math.round(window.innerWidth - at.right))}px`;
  document.body.append(panel);
  const away = (e: MouseEvent) => {
    if (!panel.contains(e.target as Node) && !chip.contains(e.target as Node)) {
      panel.remove();
      document.removeEventListener('mousedown', away);
    }
  };
  document.addEventListener('mousedown', away);
}

// ---------------------------------------------------------------- pages

const photosOf = (ids: string[]) => ids.map((id) => lib.photos.get(id)).filter((p): p is Photo => !!p);
const viewerContext = () => ({ bucket, lib: () => lib, editor, conflicts: conflictsOf });

function page(title: string | Node, subtitle: string, ...body: Node[]) {
  disposeGrid?.();
  disposeGrid = null;
  refreshSettings = null;
  main.classList.remove('has-rail');
  clear(main);
  main.append(
    h(
      'header',
      { class: 'page-head' },
      h('div', { class: 'page-title' }, typeof title === 'string' ? h('h1', {}, title) : title, subtitle ? h('div', { class: 'muted' }, subtitle) : null),
      chip,
    ),
    ...body,
  );
}

/// One icon, one line, at most one action.
function emptyState(name: IconName, text: string, action?: { label: string; icon?: IconName; run: () => void }) {
  return h(
    'div',
    { class: 'empty' },
    h('div', { class: 'empty-icon' }, icon(name, { size: 40 })),
    h('p', {}, text),
    action ? h('button', { class: 'primary', onclick: action.run }, action.icon ? icon(action.icon, { size: 18 }) : null, action.label) : null,
  );
}

const uploadAction = () => ({ label: t('upload'), icon: 'upload' as const, run: () => pickFiles((f) => uploader.add(f)) });

function gridPage(title: string | Node, subtitle: string, photos: Photo[], empty: Node, extra: Node[] = [], years = false) {
  if (photos.length === 0) return page(title, subtitle, ...extra, empty);
  page(title, subtitle, ...extra, selectionBar);
  const g = dayGrid(bucket, photos, main, (p, list) => openViewer(viewerContext(), p, list), selection, { years });
  disposeGrid = g.dispose;
  main.append(g.el);
  if (g.rail) {
    main.classList.add('has-rail');
    main.after(g.rail);
  }
  renderSelectionBar();
}

function renderSelectionBar() {
  const ids = [...selection.ids];
  selectionBar.hidden = ids.length === 0;
  if (ids.length === 0) return clear(selectionBar);
  const binned = ids.every((id) => lib.photos.get(id)?.binnedAt != null);
  const done = () => {
    selection.ids.clear();
    renderSelectionBar();
    rebuild();
  };
  const toAlbum = async () => {
    const got = await pickOrCreate(t('navAlbums'), lib.albums.map((a) => ({ id: a.id, label: a.name })), (q) => t('newAlbumNamed', q));
    if (!got) return;
    if ('create' in got) await editor.newAlbum(got.create, ids);
    else await editor.member('album', got.id, ids, true);
    toast(t('addedToAlbum', count(ids.length)));
    done();
  };
  const toPerson = async () => {
    const got = await pickOrCreate(t('navPeople'), lib.people.map((p) => ({ id: p.id, label: p.name })), (q) => t('newPersonNamed', q));
    if (!got) return;
    if ('create' in got) await editor.newPerson(got.create, ids);
    else await editor.member('person', got.id, ids, true);
    done();
  };
  const owner = currentOwner();
  const parts: (Node | null)[] = [
    h('span', { class: 'count' }, t('selectedCount', count(ids.length))),
    ...(binned
      ? [h('button', { class: 'link', onclick: () => void editor.restore(ids).then(done) }, t('restore'))]
      : [
          h('button', { class: 'link', onclick: () => void toAlbum() }, t('addToAlbum')),
          h('button', { class: 'link', onclick: () => void toPerson() }, t('addPerson')),
          h('button', { class: 'link', onclick: () => void editor.favorite(ids, true).then(done) }, t('favorite')),
          owner
            ? h(
                'button',
                { class: 'link', onclick: () => void editor.member(owner.e, owner.id, ids, false).then(done) },
                t(owner.e === 'album' ? 'removeFromAlbum' : 'removeFromPerson'),
              )
            : null,
          h(
            'button',
            {
              class: 'link danger',
              onclick: async () => {
                await editor.bin(ids);
                toast(t('binnedMany', count(ids.length)), () => void editor.restore(ids));
                done();
              },
            },
            t('delete'),
          ),
        ]),
    h('span', { class: 'spacer' }),
    h('button', { class: 'icon', title: 'Esc', 'aria-label': 'Esc', onclick: done }, icon('close', { size: 18 })),
  ];
  selectionBar.replaceChildren(...parts.filter((n): n is Node => n !== null));
}

/// The album or person whose page is open, for "Remove from …".
function currentOwner(): { e: 'album' | 'person'; id: string } | null {
  const [, kind, id] = location.hash.replace(/^#/, '').split('/');
  return (kind === 'album' || kind === 'person') && id ? { e: kind, id: decodeURIComponent(id) } : null;
}

function cover(id: string | null | undefined) {
  const img = h('img', { alt: '', decoding: 'async' });
  const p = id ? lib.photos.get(id) : undefined;
  const key = p?.thumbKey ?? p?.mediumKey;
  img.addEventListener('load', () => img.classList.add('in'), { once: true });
  if (key) void thumbUrl(bucket, key).then((u) => u && (img.src = u));
  return img;
}

function cards(items: { href: string; cover: string | null | undefined; name: string; n: number; round?: boolean }[]) {
  return h(
    'div',
    { class: 'cards' },
    ...items.map((i) =>
      h(
        'a',
        { class: `card-tile${i.round ? ' round' : ''}`, href: i.href },
        h('div', { class: 'cover' }, cover(i.cover)),
        h('div', { class: 'card-meta' }, h('div', { class: 'name' }, i.name || '—'), h('div', { class: 'muted' }, count(i.n))),
      ),
    ),
  );
}

const shownCities = 5;
/// Countries showing all their cities, and place pages with photos open.
const unfolded = new Set<string>();
const placePhotosOpen = new Set<string>();

const placeHref = (path: string[]) => `#/place/${path.map(encodeURIComponent).join('/')}`;

function placeRow(pl: Place, here: string[], indent: number): Node[] {
  const row = h(
    'a',
    { class: `place-row ${pl.level}`, style: `padding-left:${16 + indent * 22}px`, href: placeHref(here) },
    h('span', { class: 'place-name' }, pl.level === 'pin' ? `📍 ${pl.name}` : pl.name),
    h('span', { class: 'muted' }, count(pl.photos.length)),
  );
  const note = pl.description ? h('div', { class: 'place-note muted', style: `padding-left:${40 + indent * 22}px` }, pl.description) : null;
  return note ? [row, note] : [row];
}

/// [list] and everything under it; a country's cities fold past [shownCities].
function placeRows(list: Place[], indent: number, path: string[]): Node[] {
  return list.flatMap((pl): Node[] => {
    const here = [...path, pl.name];
    if (pl.level !== 'country') return [...placeRow(pl, here, indent), ...placeRows(pl.children, indent + 1, here)];
    const cities = pl.children.filter((c) => c.level === 'city');
    const pins = pl.children.filter((c) => c.level !== 'city');
    const open = unfolded.has(pl.name);
    const shown = open ? cities : cities.slice(0, shownCities);
    const fold: Node[] =
      cities.length > shownCities
        ? [
            h(
              'button',
              {
                class: 'place-fold link',
                style: `padding-left:${16 + (indent + 1) * 22}px`,
                onclick: () => {
                  if (!unfolded.delete(pl.name)) unfolded.add(pl.name);
                  route(true);
                },
              },
              open ? `${t('placesFewer')} ⌃` : `${t('placesMore', count(cities.length - shown.length))} ⌄`,
            ),
          ]
        : [];
    return [...placeRow(pl, here, indent), ...placeRows(shown, indent + 1, here), ...fold, ...placeRows(pins, indent + 1, here)];
  });
}

function findPlace(path: string[]): Place | undefined {
  let list = lib.places;
  let found: Place | undefined;
  for (const name of path) {
    found = list.find((p) => p.name === name);
    if (!found) return undefined;
    list = found.children;
  }
  return found;
}

/// A place, any level: where it is, what was written about it, what's
/// inside it, and its photos folded until asked for.
function placePage(pl: Place, path: string[], hash: string) {
  const level = { country: t('placeCountry'), city: t('placeCity'), pin: t('placePin') }[pl.level];
  const trail = h(
    'div',
    { class: 'place-trail muted' },
    h('a', { href: '#/places' }, t('navPlaces')),
    ...path.slice(0, -1).flatMap((name, i) => [' › ', h('a', { href: placeHref(path.slice(0, i + 1)) }, name)]),
  );
  const inside = pl.children.length
    ? h('div', { class: 'places' }, ...placeRows(pl.children, 0, path))
    : h('div', { class: 'muted place-empty' }, t('placeNoPins'));
  const open = placePhotosOpen.has(hash);
  const toggle = h(
    'button',
    {
      class: 'place-fold link',
      onclick: () => {
        if (!placePhotosOpen.delete(hash)) placePhotosOpen.add(hash);
        route(true);
      },
    },
    `${t('placePhotos', count(pl.photos.length))} ${open ? '⌃' : '⌄'}`,
  );
  const ids = placeIds(pl);
  const written = lib.impressions.filter((i) => ids.has(i.placeId));
  const plans = lib.plans.filter((r) => r.stops.some((s) => ids.has(s.placeId)));
  const head: Node[] = [trail];
  if (pl.description) head.push(h('p', { class: 'place-description' }, pl.description));
  head.push(h('h2', { class: 'place-section' }, t('placePins')), inside);
  if (written.length) {
    head.push(
      h('h2', { class: 'place-section' }, t('placeImpressions')),
      ...written.map((i) => impressionCard(i, pl.ids.includes(i.placeId) ? '' : (lib.placeNames.get(i.placeId) ?? ''))),
    );
  }
  if (plans.length) head.push(h('h2', { class: 'place-section' }, t('placePlans')), ...plans.map(planCard));
  if (pl.photos.length) head.push(toggle);
  if (open) return gridPage(pl.name, level, photosOf(pl.photos), emptyState('photos', t('emptyAlbum')), head);
  page(pl.name, level, ...head);
}

const shortDate = (at: number) =>
  new Date(at).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });

/// An impression in full: it's read here, not opened.
function impressionCard(i: Impression, at: string) {
  const meta = [at ? t('impressionAt', at) : '', i.at !== null ? shortDate(i.at) : ''].filter((x) => x.length > 0);
  return h(
    'article',
    { class: 'impression' },
    meta.length ? h('div', { class: 'muted' }, meta.join(' · ')) : null,
    i.text ? h('p', { class: 'impression-text' }, i.text) : null,
  );
}

function planCard(r: Plan) {
  const dates = [r.starts, r.ends].filter((x): x is number => x !== null).map(shortDate).join(' – ');
  const stops = r.stops.map((s) => lib.placeNames.get(s.placeId) ?? '').filter((n) => n.length > 0);
  return h(
    'article',
    { class: 'impression' },
    h('h3', {}, r.title || t('planUntitled')),
    dates ? h('div', { class: 'muted' }, dates) : null,
    stops.length ? h('div', { class: 'plan-stops' }, stops.join(' → ')) : null,
    r.note ? h('p', { class: 'impression-text' }, r.note) : null,
  );
}

/// A page title that edits in place: ✎ asks, and an open conflict on it says so.
function editableTitle(e: 'album' | 'person', id: string, name: string, extra: Node[] = []) {
  const conflicts = conflictsOf(e, id).filter((c) => c.f === 'name');
  return h(
    'div',
    { class: 'title-row' },
    h('h1', {}, name || '—'),
    h(
      'button',
      {
        class: 'icon',
        title: t('rename'),
        onclick: async () => {
          const v = await askText(t('rename'), name);
          if (v) await editor.set(e, id, 'name', v);
        },
      },
      '✎',
    ),
    ...conflicts.map((c) =>
      h(
        'span',
        { class: 'conflict-inline' },
        `⚠ ${t('conflictAlsoNamed', String(c.x ?? '—'))}`,
        h('button', { class: 'link', onclick: () => void editor.set(e, id, 'name', name) }, t('conflictKeep')),
        h('button', { class: 'link', onclick: () => void editor.set(e, id, 'name', c.x) }, t('conflictUseOther')),
      ),
    ),
    ...extra,
  );
}

function route(redraw = false) {
  if (!lib) return;
  const hash = location.hash;
  if (!redraw && hash !== currentRoute) selection.ids.clear();
  currentRoute = hash;
  const [, kind = 'photos', ...rest] = hash.replace(/^#/, '').split('/');
  const arg = rest.map(decodeURIComponent);
  const section = ({ album: 'albums', person: 'people', place: 'places' } as Record<string, string>)[kind] ?? kind;
  for (const a of document.querySelectorAll('nav a')) {
    const on = a.getAttribute('data-route') === section;
    a.classList.toggle('on', on);
    if (on) a.setAttribute('aria-current', 'page');
    else a.removeAttribute('aria-current');
  }
  const notFound = () => emptyState('alert', t('notFound'));
  switch (kind) {
    case 'albums': {
      const newAlbum = async () => {
        const name = await askText(t('newAlbum'), '');
        if (name) location.hash = `#/album/${await editor.newAlbum(name)}`;
      };
      const make = h('button', { class: 'btn', onclick: () => void newAlbum() }, icon('plus', { size: 16 }), t('newAlbum'));
      const title = h('div', { class: 'title-row' }, h('h1', {}, t('navAlbums')), make);
      return lib.albums.length
        ? page(title, '', cards(lib.albums.map((a) => ({ href: `#/album/${a.id}`, cover: a.cover ?? a.photos[0], name: a.name, n: a.photos.length }))))
        : page(title, '', emptyState('albums', t('emptyAlbums'), { label: t('newAlbum'), icon: 'plus', run: () => void newAlbum() }));
    }
    case 'album': {
      const a = lib.albums.find((x) => x.id === arg[0]);
      if (!a) return page(t('navAlbums'), '', notFound());
      const remove = h(
        'button',
        {
          class: 'link danger',
          onclick: async () => {
            if (!(await confirmDanger(t('deleteAlbumTitle', a.name), t('deleteAlbumBody'), t('delete')))) return;
            await editor.set('album', a.id, 'deleted_at', Date.now());
            location.hash = '#/albums';
            toast(t('albumDeleted'), () => void editor.set('album', a.id, 'deleted_at', null));
          },
        },
        t('deleteAlbum'),
      );
      return gridPage(
        editableTitle('album', a.id, a.name, [remove]),
        [t('photosCount', count(a.photos.length)), a.description].filter(Boolean).join(' · '),
        photosOf(a.photos),
        emptyState('albums', t('emptyAlbum')),
      );
    }
    case 'people':
      return lib.people.length
        ? page(t('navPeople'), '', cards(lib.people.map((p) => ({ href: `#/person/${p.id}`, cover: p.avatar ?? p.photos[0], name: p.name, n: p.photos.length, round: true }))))
        : page(t('navPeople'), '', emptyState('people', t('emptyPeople')));
    case 'person': {
      const p = lib.people.find((x) => x.id === arg[0]);
      if (!p) return page(t('navPeople'), '', notFound());
      return gridPage(editableTitle('person', p.id, p.name), t('photosCount', count(p.photos.length)), photosOf(p.photos), emptyState('people', t('emptyAlbum')));
    }
    case 'places':
      return lib.places.length
        ? page(t('navPlaces'), '', h('div', { class: 'places' }, ...placeRows(lib.places, 0, [])))
        : page(t('navPlaces'), '', emptyState('places', t('emptyPlaces')));
    case 'place': {
      const pl = findPlace(arg);
      if (!pl) return page(t('navPlaces'), '', notFound());
      return placePage(pl, arg, hash);
    }
    case 'bin':
      return gridPage(t('navBin'), t('binHint'), lib.bin, emptyState('bin', t('emptyBin')));
    case 'search': {
      const q = arg.join('/');
      const ids = search.all(q);
      return gridPage(`“${q}”`, t('photosCount', count(ids.length)), photosOf(ids), emptyState('search', t('emptySearch', q)));
    }
    case 'settings': {
      page(t('navSettings'), '');
      const view = settingsView({
        bucket,
        pullEvery,
        status: () => ({
          lastSynced,
          waiting,
          conflicts: engine.state.conflicts().length,
          error: syncError,
          busy: syncState === 'busy',
        }),
        syncNow: pull,
        disconnect,
      });
      main.append(view.el);
      refreshSettings = view.refresh;
      if (arg[0]) document.getElementById(`settings-${arg[0]}`)?.scrollIntoView();
      return;
    }
    default:
      return gridPage(t('navPhotos'), t('photosCount', count(lib.timeline.length)), lib.timeline, emptyState('photos', t('emptyPhotos'), uploadAction()), [], true);
  }
}

// ----------------------------------------------------------------- shell

function searchBox() {
  const input = h('input', { class: 'search', type: 'search', placeholder: t('searchPlaceholder') });
  const list = h('div', { class: 'suggest', hidden: true });
  const go = (hash: string) => {
    list.hidden = true;
    location.hash = hash;
  };
  input.addEventListener('input', () => {
    clear(list);
    const hits = search?.suggest(input.value) ?? [];
    list.hidden = hits.length === 0;
    for (const hit of hits) {
      const target =
        hit.kind === 'person'
          ? `#/person/${lib.people.find((p) => p.name === hit.label)?.id}`
          : hit.kind === 'album'
            ? `#/album/${lib.albums.find((a) => a.name === hit.label)?.id}`
            : `#/search/${encodeURIComponent(input.value.trim())}`;
      list.append(
        h(
          'button',
          { class: 'hit', onmousedown: (e: Event) => e.preventDefault(), onclick: () => go(target) },
          h('span', { class: 'kind' }, t(`hit_${hit.kind}`)),
          h('span', {}, hit.label),
          h('span', { class: 'muted' }, count(hit.photos.length)),
        ),
      );
    }
  });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && input.value.trim()) go(`#/search/${encodeURIComponent(input.value.trim())}`);
    if (e.key === 'Escape') list.hidden = true;
  });
  input.addEventListener('blur', () => (list.hidden = true));
  return h('div', { class: 'search-wrap' }, icon('search', { size: 18 }), input, list);
}

let dropping = false;

function shell() {
  clear(root);
  const link = (route: string, name: IconName, label: string) =>
    h('a', { href: `#/${route}`, 'data-route': route }, icon(name), h('span', {}, label));
  const brand = h('img', { class: 'brand-mark', src: 'icons/icon-48.png', alt: '', width: 28, height: 28 });
  root.append(
    h(
      'div',
      { class: 'app' },
      h(
        'header',
        { class: 'top' },
        h('a', { class: 'brand', href: '#/photos' }, brand, h('span', {}, t('name'))),
        searchBox(),
        h(
          'div',
          { class: 'top-actions' },
          syncButton,
          h('button', { class: 'primary upload-btn', onclick: () => pickFiles((f) => uploader.add(f)) }, icon('upload', { size: 18 }), t('upload')),
          h('a', { class: 'icon-btn', href: '#/settings', title: t('navSettings'), 'aria-label': t('navSettings') }, icon('settings')),
        ),
      ),
      h(
        'nav',
        {},
        link('photos', 'photos', t('navPhotos')),
        link('albums', 'albums', t('navAlbums')),
        link('people', 'people', t('navPeople')),
        link('places', 'places', t('navPlaces')),
        h('hr'),
        link('bin', 'bin', t('navBin')),
        h('span', { class: 'spacer' }),
        link('settings', 'settings', t('navSettings')),
      ),
      main,
    ),
  );
  if (!dropping) dropZone((f) => uploader.add(f));
  dropping = true;
  root.append(tray.el);
  tray.render();
  chip.onclick = () => syncPanel();
  syncButton.onclick = () => void pull();
  renderChip();
}

/// Back to setup. The bucket keeps everything; edits not yet up stay in
/// this browser until the same bucket is connected again.
async function disconnect() {
  const body = waiting > 0 ? t('changeConnectionBody', count(waiting)) : t('disconnectBody');
  if (!(await confirmDanger(t('disconnectTitle'), body, t('settingsDisconnect')))) return;
  live = false;
  clearInterval(pullTimer);
  disposeGrid?.();
  disposeGrid = null;
  refreshSettings = null;
  document.querySelector('.sync-panel')?.remove();
  const c = await loadConnection();
  await forgetConnection();
  showSetup(c ?? {});
}

function showSetup(initial: Partial<Connection>) {
  clear(root);
  root.append(h('div', { class: 'center' }, setupView(initial, (c) => void start(c))));
}

async function start(c: Connection) {
  bucket = new Bucket(c);
  live = true;
  clear(root);
  root.append(h('div', { class: 'center' }, h('div', { class: 'waiting' }, h('div', { class: 'spinner' }), h('p', {}, t('loading')))));
  try {
    engine = await Engine.open(bucket, { dbName: `pv-${c.provider}-${c.bucket}-${c.prefix}` });
  } catch {
    live = false;
    showSetup(c);
    return;
  }
  editor = new Editor(engine, rebuild, () => void engine.waiting().then((n) => ((waiting = n), renderChip())));
  uploader = new Uploader(bucket, engine, editor, () => tray.render());
  tray = uploadTray(uploader, (id) => {
    const p = lib.photos.get(id);
    if (p) openViewer(viewerContext(), p, [p]);
  });
  // Cached library first: the grid is up before the network answers.
  if (engine.hasCheckpoint) {
    lib = buildLibrary(engine.state);
    search = new SearchIndex(lib);
    shell();
    route();
  }
  await pull();
  while (!engine.hasCheckpoint) {
    clear(root);
    root.append(h('div', { class: 'center' }, waitingView(() => void disconnect())));
    await new Promise((r) => setTimeout(r, 10_000));
    if (!live) return;
    await pull();
  }
  if (!root.querySelector('.app')) {
    shell();
    route();
  }
  clearInterval(pullTimer);
  pullTimer = window.setInterval(() => {
    if (document.visibilityState === 'visible') void pull();
  }, pullEvery);
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') void pull();
});

window.addEventListener('hashchange', () => route());
window.addEventListener('online', () => void pull());
window.addEventListener('offline', () => {
  syncState = 'offline';
  renderChip();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && selection.ids.size > 0 && !document.querySelector('.viewer, dialog[open]')) {
    selection.ids.clear();
    renderSelectionBar();
    rebuild();
  }
});

void (async () => {
  document.title = t('name');
  void purgeMediaCache();
  const c = await loadConnection();
  if (c) await start(c);
  else showSetup({});
})();

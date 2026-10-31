import { Bucket, type Connection } from './bucket/client';
import { forgetConnection, loadConnection } from './connection';
import { type Library, type Photo, type Place, SearchIndex, buildLibrary } from './model';
import { Engine } from './sync/engine';
import { clear, h } from './ui/dom';
import { dayGrid } from './ui/grid';
import { ago, count, t } from './ui/i18n';
import { setupView, waitingView } from './ui/setup';
import { thumbUrl } from './ui/thumbs';
import { openViewer } from './ui/viewer';

const root = document.getElementById('app')!;
const pullEvery = 30_000;

let bucket: Bucket;
let engine: Engine;
let lib: Library;
let search: SearchIndex;
let lastSynced = 0;
let syncState: 'ok' | 'busy' | 'offline' | 'error' = 'busy';
let syncError = '';
let disposeGrid: (() => void) | null = null;

const chip = h('button', { class: 'status' });
const main = h('main', { class: 'content' });

function renderChip() {
  chip.className = `status ${syncState}`;
  chip.textContent =
    syncState === 'busy'
      ? `⟳ ${t('statusSyncing')}`
      : syncState === 'offline'
        ? t('statusOffline')
        : syncState === 'error'
          ? `⚠ ${t('statusError')}`
          : `✓ ${t('statusSynced')}`;
  chip.title = [syncError, lastSynced ? t('statusLast', ago(lastSynced)) : ''].filter(Boolean).join('\n');
}

async function pull() {
  if (!navigator.onLine) {
    syncState = 'offline';
    renderChip();
    return;
  }
  syncState = 'busy';
  renderChip();
  try {
    const applied = await engine.pull();
    lastSynced = Date.now();
    syncState = engine.fatal ? 'error' : 'ok';
    syncError = engine.fatal ? t(engine.fatal === 'newer-protocol' ? 'statusNewer' : 'statusCollision') : '';
    if (applied > 0 || !lib) {
      lib = buildLibrary(engine.state);
      search = new SearchIndex(lib);
      route();
    }
  } catch (e) {
    syncState = navigator.onLine ? 'error' : 'offline';
    syncError = String(e instanceof Error ? e.message : e);
  }
  renderChip();
}

// ---------------------------------------------------------------- routing

const photosOf = (ids: string[]) => ids.map((id) => lib.photos.get(id)).filter((p): p is Photo => !!p);

function page(title: string, subtitle: string, ...body: Node[]) {
  disposeGrid?.();
  disposeGrid = null;
  clear(main);
  main.scrollTop = 0;
  main.append(h('header', { class: 'page-head' }, h('h1', {}, title), subtitle ? h('div', { class: 'muted' }, subtitle) : null), ...body);
}

function gridPage(title: string, subtitle: string, photos: Photo[], empty: string) {
  if (photos.length === 0) return page(title, subtitle, h('div', { class: 'empty' }, empty));
  page(title, subtitle);
  const g = dayGrid(bucket, photos, main, (p, list) => openViewer(bucket, lib, p, list));
  disposeGrid = g.dispose;
  main.append(g.el);
}

function cover(id: string | null | undefined) {
  const img = h('img', { alt: '' });
  const p = id ? lib.photos.get(id) : undefined;
  const key = p?.thumbKey ?? p?.originalKey;
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
        h('div', { class: 'name' }, i.name || '—'),
        h('div', { class: 'muted' }, count(i.n)),
      ),
    ),
  );
}

function placeRows(list: Place[], depth: number, path: string[]): Node[] {
  return list.flatMap((pl) => {
    const here = [...path, pl.name];
    const row = h(
      'a',
      { class: `place-row ${pl.level}`, style: `padding-left:${16 + depth * 22}px`, href: `#/place/${here.map(encodeURIComponent).join('/')}` },
      h('span', { class: 'place-name' }, pl.level === 'pin' ? `📍 ${pl.name}` : pl.name),
      h('span', { class: 'muted' }, count(pl.photos.length)),
    );
    const note = pl.description
      ? h('div', { class: 'place-note muted', style: `padding-left:${40 + depth * 22}px` }, pl.description)
      : null;
    return [row, ...(note ? [note] : []), ...placeRows(pl.children, depth + 1, here)];
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

function route() {
  if (!lib) return;
  const [, kind = 'photos', ...rest] = location.hash.replace(/^#/, '').split('/');
  const arg = rest.map(decodeURIComponent);
  for (const a of document.querySelectorAll('nav a')) {
    a.classList.toggle('on', a.getAttribute('data-route') === kind || (kind === 'album' && a.getAttribute('data-route') === 'albums') || (kind === 'person' && a.getAttribute('data-route') === 'people') || (kind === 'place' && a.getAttribute('data-route') === 'places'));
  }
  switch (kind) {
    case 'albums':
      return lib.albums.length
        ? page(t('navAlbums'), '', cards(lib.albums.map((a) => ({ href: `#/album/${a.id}`, cover: a.cover ?? a.photos[0], name: a.name, n: a.photos.length }))))
        : page(t('navAlbums'), '', h('div', { class: 'empty' }, t('emptyAlbums')));
    case 'album': {
      const a = lib.albums.find((x) => x.id === arg[0]);
      if (!a) return page(t('navAlbums'), '', h('div', { class: 'empty' }, t('notFound')));
      return gridPage(a.name, [t('photosCount', count(a.photos.length)), a.description].filter(Boolean).join(' · '), photosOf(a.photos), t('emptyAlbum'));
    }
    case 'people':
      return lib.people.length
        ? page(t('navPeople'), '', cards(lib.people.map((p) => ({ href: `#/person/${p.id}`, cover: p.avatar ?? p.photos[0], name: p.name, n: p.photos.length, round: true }))))
        : page(t('navPeople'), '', h('div', { class: 'empty' }, t('emptyPeople')));
    case 'person': {
      const p = lib.people.find((x) => x.id === arg[0]);
      if (!p) return page(t('navPeople'), '', h('div', { class: 'empty' }, t('notFound')));
      return gridPage(p.name, t('photosCount', count(p.photos.length)), photosOf(p.photos), t('emptyAlbum'));
    }
    case 'places':
      return lib.places.length
        ? page(t('navPlaces'), '', h('div', { class: 'places' }, ...placeRows(lib.places, 0, [])))
        : page(t('navPlaces'), '', h('div', { class: 'empty' }, t('emptyPlaces')));
    case 'place': {
      const pl = findPlace(arg);
      if (!pl) return page(t('navPlaces'), '', h('div', { class: 'empty' }, t('notFound')));
      return gridPage(pl.name, [t('photosCount', count(pl.photos.length)), pl.description ?? ''].filter(Boolean).join(' · '), photosOf(pl.photos), t('emptyAlbum'));
    }
    case 'bin':
      return gridPage(t('navBin'), t('binHint'), lib.bin, t('emptyBin'));
    case 'search': {
      const q = arg.join('/');
      const ids = search.all(q);
      return gridPage(`“${q}”`, t('photosCount', count(ids.length)), photosOf(ids), t('emptySearch', q));
    }
    default:
      return gridPage(t('navPhotos'), '', lib.timeline, t('emptyPhotos'));
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
  return h('div', { class: 'search-wrap' }, input, list);
}

function shell() {
  clear(root);
  const link = (route: string, label: string) => h('a', { href: `#/${route}`, 'data-route': route }, label);
  root.append(
    h(
      'div',
      { class: 'app' },
      h('div', { class: 'top' }, h('div', { class: 'brand' }, t('name')), searchBox(), chip),
      h(
        'nav',
        {},
        link('photos', t('navPhotos')),
        link('albums', t('navAlbums')),
        link('people', t('navPeople')),
        link('places', t('navPlaces')),
        h('hr'),
        link('bin', t('navBin')),
        h('span', { class: 'spacer' }),
        h('button', { class: 'link', onclick: () => void changeConnection() }, `⚙ ${t('navConnection')}`),
      ),
      main,
    ),
  );
  chip.onclick = () => void pull();
  renderChip();
}

async function changeConnection() {
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
  clear(root);
  root.append(h('div', { class: 'center' }, h('div', { class: 'waiting' }, h('div', { class: 'spinner' }), h('p', {}, t('loading')))));
  try {
    engine = await Engine.open(bucket, { dbName: `pv-${c.provider}-${c.bucket}-${c.prefix}` });
  } catch (e) {
    showSetup(c);
    return;
  }
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
    root.append(h('div', { class: 'center' }, waitingView(() => void changeConnection())));
    await new Promise((r) => setTimeout(r, 10_000));
    await pull();
  }
  if (!root.querySelector('.app')) {
    shell();
    route();
  }
  setInterval(() => {
    if (document.visibilityState === 'visible') void pull();
  }, pullEvery);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') void pull();
  });
}

window.addEventListener('hashchange', route);
window.addEventListener('online', () => void pull());
window.addEventListener('offline', () => {
  syncState = 'offline';
  renderChip();
});

void (async () => {
  document.title = t('name');
  const c = await loadConnection();
  if (c) await start(c);
  else showSetup({});
})();

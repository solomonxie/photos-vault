import { Bucket, type Connection } from './bucket/client';
import { forgetConnection, loadConnection } from './connection';
import { type Library, type Photo, type Place, SearchIndex, buildLibrary } from './model';
import { Engine } from './sync/engine';
import type { Conflict } from './sync/merge';
import { clear, h } from './ui/dom';
import { Editor, askText, confirmDanger, pickOrCreate, toast } from './ui/edits';
import { type Selection, dayGrid } from './ui/grid';
import { ago, count, t } from './ui/i18n';
import { setupView, waitingView } from './ui/setup';
import { thumbUrl } from './ui/thumbs';
import { openViewer, viewerRefresh } from './ui/viewer';

const root = document.getElementById('app')!;
const pullEvery = 30_000;

let bucket: Bucket;
let engine: Engine;
let editor: Editor;
let lib: Library;
let search: SearchIndex;
let lastSynced = 0;
let waiting = 0;
let syncState: 'ok' | 'busy' | 'offline' | 'error' = 'busy';
let syncError = '';
let disposeGrid: (() => void) | null = null;
let currentRoute = '';
const selection: Selection = { ids: new Set(), changed: () => renderSelectionBar() };

const chip = h('button', { class: 'status' });
const main = h('main', { class: 'content' });
const selectionBar = h('div', { class: 'selection-bar', hidden: true });

const conflictsOf = (e: string, id: string): Conflict[] => {
  const ent = engine.state.entities.get(`${e}/${id}`);
  if (!ent) return [];
  return engine.state.conflicts().filter((c) => c.e === e && c.id === id);
};

function renderChip() {
  const conflicts = engine ? engine.state.conflicts().length : 0;
  chip.className = `status ${syncState}`;
  chip.textContent =
    syncState === 'busy'
      ? `⟳ ${t('statusSyncing')}`
      : syncState === 'offline'
        ? t('statusOffline')
        : syncState === 'error'
          ? `⚠ ${t('statusError')}`
          : conflicts > 0
            ? `⚠ ${t('statusConflicts', count(conflicts))}`
            : waiting > 0
              ? `↑ ${t('statusWaiting', count(waiting))}`
              : `✓ ${t('statusSynced')}`;
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
    h('button', { class: 'link', onclick: () => void pull() }, t('syncNow')),
  );
  document.body.append(panel);
  const away = (e: MouseEvent) => {
    if (!panel.contains(e.target as Node) && e.target !== chip) {
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
  clear(main);
  main.append(
    h('header', { class: 'page-head' }, typeof title === 'string' ? h('h1', {}, title) : title, subtitle ? h('div', { class: 'muted' }, subtitle) : null),
    ...body,
  );
}

function gridPage(title: string | Node, subtitle: string, photos: Photo[], empty: string, extra: Node[] = []) {
  if (photos.length === 0) return page(title, subtitle, ...extra, h('div', { class: 'empty' }, empty));
  page(title, subtitle, ...extra, selectionBar);
  const g = dayGrid(bucket, photos, main, (p, list) => openViewer(viewerContext(), p, list), selection);
  disposeGrid = g.dispose;
  main.append(g.el);
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
    h('button', { class: 'icon', title: 'Esc', onclick: done }, '✕'),
  ];
  selectionBar.replaceChildren(...parts.filter((n): n is Node => n !== null));
}

/// The album or person whose page is open, for "Remove from …".
function currentOwner(): { e: 'album' | 'person'; id: string } | null {
  const [, kind, id] = location.hash.replace(/^#/, '').split('/');
  return (kind === 'album' || kind === 'person') && id ? { e: kind, id: decodeURIComponent(id) } : null;
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
    const note = pl.description ? h('div', { class: 'place-note muted', style: `padding-left:${40 + depth * 22}px` }, pl.description) : null;
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
  for (const a of document.querySelectorAll('nav a')) a.classList.toggle('on', a.getAttribute('data-route') === section);
  switch (kind) {
    case 'albums': {
      const make = h(
        'button',
        {
          class: 'link',
          onclick: async () => {
            const name = await askText(t('newAlbum'), '');
            if (name) location.hash = `#/album/${await editor.newAlbum(name)}`;
          },
        },
        `＋ ${t('newAlbum')}`,
      );
      return lib.albums.length
        ? page(h('div', { class: 'title-row' }, h('h1', {}, t('navAlbums')), make), '', cards(lib.albums.map((a) => ({ href: `#/album/${a.id}`, cover: a.cover ?? a.photos[0], name: a.name, n: a.photos.length }))))
        : page(h('div', { class: 'title-row' }, h('h1', {}, t('navAlbums')), make), '', h('div', { class: 'empty' }, t('emptyAlbums')));
    }
    case 'album': {
      const a = lib.albums.find((x) => x.id === arg[0]);
      if (!a) return page(t('navAlbums'), '', h('div', { class: 'empty' }, t('notFound')));
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
      return gridPage(editableTitle('album', a.id, a.name, [remove]), [t('photosCount', count(a.photos.length)), a.description].filter(Boolean).join(' · '), photosOf(a.photos), t('emptyAlbum'));
    }
    case 'people':
      return lib.people.length
        ? page(t('navPeople'), '', cards(lib.people.map((p) => ({ href: `#/person/${p.id}`, cover: p.avatar ?? p.photos[0], name: p.name, n: p.photos.length, round: true }))))
        : page(t('navPeople'), '', h('div', { class: 'empty' }, t('emptyPeople')));
    case 'person': {
      const p = lib.people.find((x) => x.id === arg[0]);
      if (!p) return page(t('navPeople'), '', h('div', { class: 'empty' }, t('notFound')));
      return gridPage(editableTitle('person', p.id, p.name), t('photosCount', count(p.photos.length)), photosOf(p.photos), t('emptyAlbum'));
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
  chip.onclick = () => syncPanel();
  renderChip();
}

async function changeConnection() {
  if (waiting > 0 && !(await confirmDanger(t('changeConnectionTitle'), t('changeConnectionBody', count(waiting)), t('changeConnection')))) return;
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
  } catch {
    showSetup(c);
    return;
  }
  editor = new Editor(engine, rebuild, () => void engine.waiting().then((n) => ((waiting = n), renderChip())));
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
  const c = await loadConnection();
  if (c) await start(c);
  else showSetup({});
})();

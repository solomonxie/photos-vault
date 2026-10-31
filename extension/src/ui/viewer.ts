import type { Bucket } from '../bucket/client';
import type { Library, Photo } from '../model';
import type { Conflict } from '../sync/merge';
import { h } from './dom';
import { type Editor, askText, pickOrCreate, toast } from './edits';
import { fullDate, t } from './i18n';
import { thumbUrl, viewUrl } from './thumbs';

const showable = /\.(jpe?g|png|webp|gif|avif)$/i;
const fileName = (key: string) => key.split('/').pop() ?? key;

export interface ViewerContext {
  bucket: Bucket;
  lib: () => Library;
  editor: Editor;
  conflicts: (e: string, id: string) => Conflict[];
}

const typing = () => {
  const el = document.activeElement;
  return el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement;
};

/// Datetime-local wants local wall time with no zone.
const toLocalInput = (ms: number) => {
  const d = new Date(ms);
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 16);
};

function askDate(title: string, ms: number): Promise<number | null> {
  return new Promise((resolve) => {
    const input = h('input', { class: 'field', type: 'datetime-local' });
    input.value = toLocalInput(ms);
    const dialog = h(
      'dialog',
      { class: 'picker' },
      h(
        'form',
        { method: 'dialog' },
        h('div', { class: 'picker-title' }, title),
        input,
        h(
          'div',
          { class: 'actions' },
          h('button', { class: 'link', value: 'no' }, t('cancel')),
          h('button', { class: 'primary', value: 'yes' }, t('save')),
        ),
      ),
    );
    dialog.addEventListener('close', () => {
      dialog.remove();
      const at = new Date(input.value).getTime();
      resolve(dialog.returnValue === 'yes' && Number.isFinite(at) && at !== ms ? at : null);
    });
    document.body.append(dialog);
    dialog.showModal();
  });
}

/// The full-size view over whichever grid opened it; Esc lands back on the
/// same scroll position because the grid underneath never went away.
export function openViewer(ctx: ViewerContext, start: Photo, list: Photo[]) {
  const ids = list.map((p) => p.id);
  let index = Math.max(0, ids.indexOf(start.id));
  let shownId = '';
  const current = () => ctx.lib().photos.get(ids[index]!);
  const stage = h('div', { class: 'stage' });
  const info = h('aside', { class: 'info' });
  const actions = h('div', { class: 'viewer-actions' });
  const overlay = h(
    'div',
    { class: 'viewer', tabindex: '-1' },
    h('div', { class: 'viewer-bar' }, h('button', { class: 'icon', title: 'Esc', onclick: () => close() }, '✕'), h('span', { class: 'spacer' }), actions),
    h('button', { class: 'nav prev', onclick: () => step(-1) }, '‹'),
    stage,
    h('button', { class: 'nav next', onclick: () => step(1) }, '›'),
    info,
  );

  const renderStage = async (p: Photo) => {
    stage.replaceChildren();
    const thumb = p.thumbKey ?? p.originalKey;
    if (p.isVideo && p.originalKey) {
      const v = h('video', { controls: true, autoplay: true, playsinline: true });
      if (thumb) void thumbUrl(ctx.bucket, thumb).then((u) => u && (v.poster = u));
      v.src = await viewUrl(ctx.bucket, p.originalKey);
      stage.append(v);
      return;
    }
    const img = h('img', { alt: '' });
    if (thumb) void thumbUrl(ctx.bucket, thumb).then((u) => u && !img.dataset.full && (img.src = u));
    stage.append(img);
    const full = [p.editedKey, p.mediumKey, p.originalKey].find((k) => k && showable.test(k));
    if (full) {
      const pre = new Image();
      pre.onload = () => {
        img.dataset.full = '1';
        img.src = pre.src;
      };
      pre.src = await viewUrl(ctx.bucket, full);
    } else if (p.originalKey) {
      stage.append(h('div', { class: 'note' }, t('viewerHeic')));
    }
  };

  const binIt = async (p: Photo) => {
    await ctx.editor.bin([p.id]);
    close();
    toast(t('binnedOne'), () => void ctx.editor.restore([p.id]));
  };

  const renderActions = (p: Photo) => {
    const parts: (Node | null)[] = [
      h(
        'button',
        { class: `icon${p.favorite ? ' fav' : ''}`, title: 'F', onclick: () => void ctx.editor.favorite([p.id], !p.favorite) },
        p.favorite ? '♥' : '♡',
      ),
      p.originalKey
        ? h(
            'button',
            {
              class: 'icon',
              title: t('viewerDownload'),
              onclick: async () => h('a', { href: await viewUrl(ctx.bucket, p.originalKey!, fileName(p.originalKey!)) }).click(),
            },
            '⇩',
          )
        : null,
      p.binnedAt === null
        ? h('button', { class: 'icon', title: '⌫', onclick: () => void binIt(p) }, '🗑')
        : h('button', { class: 'link', onclick: () => void ctx.editor.restore([p.id]) }, t('restore')),
    ];
    actions.replaceChildren(...parts.filter((n): n is Node => n !== null));
  };

  const chip = (label: string, href: string | null, remove: () => void) =>
    h(
      'span',
      { class: 'chip' },
      href ? h('a', { href, onclick: () => close() }, label) : label,
      h('button', { class: 'chip-x', title: t('remove'), onclick: remove }, '✕'),
    );
  const add = (onclick: () => void) => h('button', { class: 'chip add', onclick }, '＋');

  const conflictCard = (c: Conflict, mine: string) =>
    h(
      'div',
      { class: 'conflict' },
      h('div', { class: 'conflict-title' }, `⚠ ${t(c.f === 'location' ? 'conflictLocation' : 'conflictDescription')}`),
      h('div', { class: 'muted' }, t('conflictShown')),
      h('div', {}, mine || '—'),
      h('div', { class: 'muted' }, t('conflictOther')),
      h('div', {}, String(c.x ?? '—')),
      h(
        'div',
        { class: 'actions' },
        h('button', { class: 'link', onclick: () => void ctx.editor.set(c.e, c.id, c.f, mine) }, t('conflictKeep')),
        h('button', { class: 'link', onclick: () => void ctx.editor.set(c.e, c.id, c.f, c.x) }, t('conflictUseOther')),
      ),
    );

  const renderInfo = (p: Photo) => {
    const lib = ctx.lib();
    const people = (lib.peopleOf.get(p.id) ?? []).map((id) => lib.people.find((x) => x.id === id)).filter((x) => !!x);
    const albums = (lib.albumsOf.get(p.id) ?? []).map((id) => lib.albums.find((x) => x.id === id)).filter((x) => !!x);
    const row = (title: string, ...body: (Node | string | null)[]) =>
      h('div', { class: 'card-row' }, h('div', { class: 'card-title' }, title), h('div', { class: 'card-body' }, ...body));

    const description = h('textarea', { class: 'describe', rows: 2, placeholder: t('viewerAddDescription') });
    description.value = p.description;
    const saveDescription = () => {
      const v = description.value.trim();
      if (v !== p.description.trim()) void ctx.editor.set('asset', p.id, 'description', v);
    };
    description.addEventListener('blur', saveDescription);
    description.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) description.blur();
      if (e.key === 'Escape') {
        description.value = p.description;
        description.blur();
      }
    });

    const addPerson = async () => {
      const got = await pickOrCreate(
        t('navPeople'),
        lib.people.map((x) => ({ id: x.id, label: x.name, checked: x.photos.includes(p.id) })),
        (q) => t('newPersonNamed', q),
      );
      if (!got) return;
      if ('create' in got) await ctx.editor.newPerson(got.create, [p.id]);
      else await ctx.editor.member('person', got.id, [p.id], true);
    };
    const addAlbum = async () => {
      const got = await pickOrCreate(
        t('navAlbums'),
        lib.albums.map((x) => ({ id: x.id, label: x.name, checked: x.photos.includes(p.id) })),
        (q) => t('newAlbumNamed', q),
      );
      if (!got) return;
      if ('create' in got) await ctx.editor.newAlbum(got.create, [p.id]);
      else await ctx.editor.member('album', got.id, [p.id], true);
    };
    const addTag = async () => {
      const all = new Set([...lib.timeline.flatMap((x) => x.tags)]);
      const got = await pickOrCreate(
        t('viewerTags'),
        [...all].filter((x) => !p.tags.includes(x)).sort().map((x) => ({ id: x, label: x })),
        (q) => t('newTagNamed', q),
      );
      if (!got) return;
      await ctx.editor.tag(p.id, 'create' in got ? got.create : got.id, true);
    };
    const editLocation = async () => {
      const v = await askText(t('viewerLocation'), p.location);
      if (v !== null) await ctx.editor.set('asset', p.id, 'location', v || null);
    };
    const editDate = async () => {
      const v = await askDate(t('viewerTaken'), p.takenAt);
      if (v !== null) await ctx.editor.set('asset', p.id, 'created_at', v);
    };

    const conflicts = ctx.conflicts('asset', p.id);
    const parts: (Node | null)[] = [
      h('button', { class: 'when', title: t('viewerTaken'), onclick: () => void editDate() }, `${fullDate(p.takenAt)}  ✎`),
      h('div', { class: 'muted' }, [p.originalKey ? fileName(p.originalKey) : '', p.width ? `${p.width}×${p.height}` : ''].filter(Boolean).join(' · ')),
      p.binnedAt !== null ? h('div', { class: 'banner' }, t('viewerBinned')) : null,
      ...conflicts.map((c) => conflictCard(c, c.f === 'location' ? p.location : p.description)),
      h('div', { class: 'card text' }, description),
      h(
        'div',
        { class: 'card' },
        row(t('navPeople'), ...people.map((x) => chip(x.name, `#/person/${x.id}`, () => void ctx.editor.member('person', x.id, [p.id], false))), add(() => void addPerson())),
        row(t('navAlbums'), ...albums.map((x) => chip(x.name || '—', `#/album/${x.id}`, () => void ctx.editor.member('album', x.id, [p.id], false))), add(() => void addAlbum())),
        row(t('viewerTags'), ...p.tags.map((x) => chip(x, null, () => void ctx.editor.tag(p.id, x, false))), add(() => void addTag())),
        row(t('viewerLocation'), h('button', { class: 'plain', onclick: () => void editLocation() }, `${p.location || '—'}  ✎`)),
      ),
    ];
    info.replaceChildren(...parts.filter((n): n is Node => n !== null));
  };

  /// Redraws from the current library; the image only when the photo changed.
  const render = () => {
    const p = current();
    if (!p) return close();
    if (p.id !== shownId) {
      shownId = p.id;
      void renderStage(p);
    }
    renderActions(p);
    if (!info.contains(document.activeElement)) renderInfo(p);
  };

  const step = (d: number) => {
    const next = index + d;
    if (next < 0 || next >= ids.length) return;
    index = next;
    render();
  };
  const onKey = (e: KeyboardEvent) => {
    if (document.querySelector('dialog[open]')) return;
    if (e.key === 'Escape' && !typing()) close();
    if (typing()) return;
    if (e.key === 'ArrowLeft') step(-1);
    else if (e.key === 'ArrowRight') step(1);
    else if (e.key === 'f' || e.key === 'F') {
      const p = current();
      if (p) void ctx.editor.favorite([p.id], !p.favorite);
    } else if (e.key === 'Delete' || e.key === 'Backspace') {
      const p = current();
      if (p && p.binnedAt === null) void binIt(p);
    }
  };
  const close = () => {
    document.removeEventListener('keydown', onKey);
    overlay.remove();
    viewerRefresh = null;
  };
  document.addEventListener('keydown', onKey);
  document.body.append(overlay);
  overlay.focus();
  viewerRefresh = render;
  render();
}

/// The open viewer's redraw, for edits and pulls to call.
export let viewerRefresh: (() => void) | null = null;

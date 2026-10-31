import type { Bucket } from '../bucket/client';
import type { Library, Photo } from '../model';
import { h } from './dom';
import { fullDate, t } from './i18n';
import { thumbUrl, viewUrl } from './thumbs';

const showable = /\.(jpe?g|png|webp|gif|avif)$/i;
const fileName = (key: string) => key.split('/').pop() ?? key;

/// The full-size view over whichever grid opened it; Esc lands back on the
/// same scroll position because the grid underneath never went away.
export function openViewer(bucket: Bucket, lib: Library, start: Photo, list: Photo[]) {
  let index = Math.max(0, list.findIndex((p) => p.id === start.id));
  const stage = h('div', { class: 'stage' });
  const info = h('aside', { class: 'info' });
  const overlay = h(
    'div',
    { class: 'viewer', tabindex: '-1' },
    h(
      'div',
      { class: 'viewer-bar' },
      h('button', { class: 'icon', title: 'Esc', onclick: () => close() }, '✕'),
      h('span', { class: 'spacer' }),
    ),
    h('button', { class: 'nav prev', onclick: () => step(-1) }, '‹'),
    stage,
    h('button', { class: 'nav next', onclick: () => step(1) }, '›'),
    info,
  );

  const render = async () => {
    const p = list[index]!;
    stage.replaceChildren();
    const thumb = p.thumbKey ?? p.originalKey;
    if (p.isVideo && p.originalKey) {
      const v = h('video', { controls: true, autoplay: true, playsinline: true });
      if (thumb) void thumbUrl(bucket, thumb).then((u) => u && (v.poster = u));
      v.src = await viewUrl(bucket, p.originalKey);
      stage.append(v);
    } else {
      const img = h('img', { alt: '' });
      if (thumb) void thumbUrl(bucket, thumb).then((u) => u && !img.dataset.full && (img.src = u));
      stage.append(img);
      const full = [p.editedKey, p.mediumKey, p.originalKey].find((k) => k && showable.test(k));
      if (full) {
        const pre = new Image();
        pre.onload = () => {
          img.dataset.full = '1';
          img.src = pre.src;
        };
        pre.src = await viewUrl(bucket, full);
      } else if (p.originalKey) {
        stage.append(h('div', { class: 'note' }, t('viewerHeic')));
      }
    }
    renderInfo(p);
  };

  const chip = (label: string, hash: string) =>
    h('a', { class: 'chip', href: hash, onclick: () => close() }, label);

  const renderInfo = (p: Photo) => {
    const people = (lib.peopleOf.get(p.id) ?? []).map((id) => lib.people.find((x) => x.id === id)).filter((x) => !!x);
    const albums = (lib.albumsOf.get(p.id) ?? []).map((id) => lib.albums.find((x) => x.id === id)).filter((x) => !!x);
    const card = (title: string, ...body: (Node | string)[]) =>
      h('div', { class: 'card-row' }, h('div', { class: 'card-title' }, title), h('div', { class: 'card-body' }, ...body));
    const parts: (Node | null)[] = [
      h('div', { class: 'when' }, fullDate(p.takenAt)),
      h('div', { class: 'muted' }, [p.originalKey ? fileName(p.originalKey) : '', p.width ? `${p.width}×${p.height}` : ''].filter(Boolean).join(' · ')),
      p.binnedAt !== null ? h('div', { class: 'banner' }, t('viewerBinned')) : null,
      h('div', { class: 'card text' }, p.description || h('span', { class: 'muted' }, t('viewerNoDescription'))),
      h(
        'div',
        { class: 'card' },
        card(t('navPeople'), ...(people.length ? people.map((x) => chip(x.name, `#/person/${x.id}`)) : ['—'])),
        card(t('navAlbums'), ...(albums.length ? albums.map((x) => chip(x.name || '—', `#/album/${x.id}`)) : ['—'])),
        card(t('viewerTags'), ...(p.tags.length ? p.tags.map((x) => h('span', { class: 'chip' }, x)) : ['—'])),
        card(t('viewerLocation'), p.location || '—'),
      ),
      p.originalKey
        ? h(
            'button',
            {
              class: 'link',
              onclick: async () => {
                const a = h('a', { href: await viewUrl(bucket, p.originalKey!, fileName(p.originalKey!)) });
                a.click();
              },
            },
            t('viewerDownload'),
          )
        : null,
    ];
    info.replaceChildren(...parts.filter((n): n is Node => n !== null));
  };

  const step = (d: number) => {
    const next = index + d;
    if (next < 0 || next >= list.length) return;
    index = next;
    void render();
  };
  const onKey = (e: KeyboardEvent) => {
    if (e.key === 'Escape') close();
    else if (e.key === 'ArrowLeft') step(-1);
    else if (e.key === 'ArrowRight') step(1);
  };
  const close = () => {
    document.removeEventListener('keydown', onKey);
    overlay.remove();
  };
  document.addEventListener('keydown', onKey);
  document.body.append(overlay);
  overlay.focus();
  void render();
}

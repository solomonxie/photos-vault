import type { Bucket } from '../bucket/client';
import { type Photo, groupByDay } from '../model';
import { clear, h } from './dom';
import { dayLabel } from './i18n';
import { thumbUrl } from './thumbs';

const headerHeight = 44;
const gap = 3;

interface Row {
  top: number;
  height: number;
  header?: string;
  photos?: Photo[];
}

/// The day grid every page uses. Only rows within a screen of the viewport
/// exist in the DOM; a library of tens of thousands is a few hundred nodes.
export function dayGrid(
  bucket: Bucket,
  photos: Photo[],
  scroller: HTMLElement,
  onOpen: (photo: Photo, list: Photo[]) => void,
): { el: HTMLElement; dispose: () => void } {
  const el = h('div', { class: 'grid' });
  const days = groupByDay(photos);
  let rows: Row[] = [];
  let width = 0;
  const live = new Map<number, HTMLElement>();

  const layout = () => {
    width = el.clientWidth;
    const cols = Math.max(3, Math.min(10, Math.floor(width / 170)));
    const tile = (width - gap * (cols - 1)) / cols;
    rows = [];
    let top = 0;
    for (const d of days) {
      rows.push({ top, height: headerHeight, header: dayLabel(d.at, d.place) });
      top += headerHeight;
      for (let i = 0; i < d.photos.length; i += cols) {
        rows.push({ top, height: tile, photos: d.photos.slice(i, i + cols) });
        top += tile + gap;
      }
    }
    el.style.height = `${top}px`;
    for (const node of live.values()) node.remove();
    live.clear();
    paint();
  };

  const tileFor = (p: Photo, size: number) => {
    const img = h('img', { alt: '', draggable: 'false', decoding: 'async' });
    const key = p.thumbKey ?? p.originalKey;
    if (key) void thumbUrl(bucket, key).then((u) => u && (img.src = u));
    return h(
      'button',
      {
        class: 'tile',
        style: `width:${size}px;height:${size}px`,
        title: p.description || '',
        onclick: () => onOpen(p, photos),
      },
      img,
      p.isVideo ? h('span', { class: 'badge video' }, '▶') : null,
      p.isLive ? h('span', { class: 'badge' }, 'LIVE') : null,
      p.favorite ? h('span', { class: 'badge fav' }, '♥') : null,
      p.thumbKey ? null : h('span', { class: 'badge wait' }, '⌛'),
    );
  };

  const paint = () => {
    const viewTop = scroller.scrollTop - el.offsetTop;
    const vh = scroller.clientHeight;
    const from = viewTop - vh;
    const to = viewTop + 2 * vh;
    // First row at or past `from`: rows are sorted by top.
    let lo = 0;
    let hi = rows.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (rows[mid]!.top + rows[mid]!.height < from) lo = mid + 1;
      else hi = mid;
    }
    const want = new Set<number>();
    for (let i = lo; i < rows.length && rows[i]!.top < to; i++) want.add(i);
    for (const [i, node] of live) {
      if (!want.has(i)) {
        node.remove();
        live.delete(i);
      }
    }
    for (const i of want) {
      if (live.has(i)) continue;
      const r = rows[i]!;
      const node = r.header
        ? h('div', { class: 'day', style: `top:${r.top}px` }, r.header)
        : h('div', { class: 'row', style: `top:${r.top}px;height:${r.height}px` }, ...r.photos!.map((p) => tileFor(p, r.height)));
      live.set(i, node);
      el.append(node);
    }
  };

  let frame = 0;
  const onScroll = () => {
    if (frame) return;
    frame = requestAnimationFrame(() => {
      frame = 0;
      paint();
    });
  };
  const resize = new ResizeObserver(() => {
    if (el.clientWidth !== width) layout();
  });
  scroller.addEventListener('scroll', onScroll, { passive: true });
  resize.observe(el);
  queueMicrotask(layout);
  return {
    el,
    dispose: () => {
      scroller.removeEventListener('scroll', onScroll);
      resize.disconnect();
      clear(el);
    },
  };
}

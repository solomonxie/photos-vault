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

export interface Selection {
  ids: Set<string>;
  /// After any change, for the bar above the grid.
  changed: () => void;
}

/// The day grid every page uses. Only rows within a screen of the viewport
/// exist in the DOM; a library of tens of thousands is a few hundred nodes.
export function dayGrid(
  bucket: Bucket,
  photos: Photo[],
  scroller: HTMLElement,
  onOpen: (photo: Photo, list: Photo[]) => void,
  selection?: Selection,
): { el: HTMLElement; dispose: () => void; refresh: () => void } {
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

  const order = new Map(photos.map((p, i) => [p.id, i]));
  let anchor: number | null = null;

  const toggle = (p: Photo, range: boolean) => {
    if (!selection) return;
    const i = order.get(p.id)!;
    if (range && anchor !== null) {
      const [a, b] = anchor < i ? [anchor, i] : [i, anchor];
      for (let k = a; k <= b; k++) selection.ids.add(photos[k]!.id);
    } else if (selection.ids.has(p.id)) {
      selection.ids.delete(p.id);
    } else {
      selection.ids.add(p.id);
    }
    anchor = i;
    refresh();
    selection.changed();
  };

  /// Repaints the checkmarks on the tiles that exist, nothing else.
  const refresh = () => {
    for (const tile of el.querySelectorAll<HTMLElement>('.tile')) {
      tile.classList.toggle('picked', !!selection?.ids.has(tile.dataset.id!));
    }
    el.classList.toggle('selecting', (selection?.ids.size ?? 0) > 0);
  };

  const tileFor = (p: Photo, size: number) => {
    const img = h('img', { alt: '', draggable: 'false', decoding: 'async' });
    const key = p.thumbKey ?? p.originalKey;
    if (key) void thumbUrl(bucket, key).then((u) => u && (img.src = u));
    const tile = h(
      'button',
      {
        class: `tile${selection?.ids.has(p.id) ? ' picked' : ''}`,
        style: `width:${size}px;height:${size}px`,
        title: p.description || '',
        'data-id': p.id,
        onclick: (e: Event) => {
          const ev = e as MouseEvent;
          if (selection && (selection.ids.size > 0 || ev.shiftKey || ev.metaKey)) toggle(p, ev.shiftKey);
          else onOpen(p, photos);
        },
      },
      selection
        ? h('span', {
            class: 'pick-dot',
            onclick: (e: Event) => {
              e.stopPropagation();
              toggle(p, (e as MouseEvent).shiftKey);
            },
          })
        : null,
      img,
      p.isVideo ? h('span', { class: 'badge video' }, '▶') : null,
      p.isLive ? h('span', { class: 'badge' }, 'LIVE') : null,
      p.favorite ? h('span', { class: 'badge fav' }, '♥') : null,
      p.thumbKey ? null : h('span', { class: 'badge wait' }, '⌛'),
    );
    return tile;
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
    refresh,
    dispose: () => {
      scroller.removeEventListener('scroll', onScroll);
      resize.disconnect();
      clear(el);
    },
  };
}

import type { Bucket } from '../bucket/client';
import { type Photo, groupByDay } from '../model';
import { clear, h } from './dom';
import { dayLabel, t } from './i18n';
import { icon } from './icons';
import { thumbUrl } from './thumbs';

const headerHeight = 48;
const gap = 4;
/// Year labels closer than this share of the rail would overlap.
const yearSpacing = 0.035;

interface Row {
  top: number;
  height: number;
  header?: string;
  day?: Photo[];
  photos?: Photo[];
}

export interface Selection {
  ids: Set<string>;
  /// After any change, for the bar above the grid.
  changed: () => void;
}

/// The day grid every page uses. Only rows within a screen of the viewport
/// exist in the DOM; a library of tens of thousands is a few hundred nodes.
/// With `years`, a rail on the right jumps between years; its offsets are
/// worked out once per layout, never per scroll.
export function dayGrid(
  bucket: Bucket,
  photos: Photo[],
  scroller: HTMLElement,
  onOpen: (photo: Photo, list: Photo[]) => void,
  selection?: Selection,
  opts: { years?: boolean } = {},
): { el: HTMLElement; rail: HTMLElement | null; dispose: () => void; refresh: () => void } {
  const el = h('div', { class: 'grid' });
  const days = groupByDay(photos);
  let rows: Row[] = [];
  let width = 0;
  let total = 0;
  const live = new Map<number, HTMLElement>();

  const rail = opts.years ? h('div', { class: 'year-rail', role: 'navigation', 'aria-label': t('yearRail') }) : null;
  const marker = h('span', { class: 'year-marker' });
  let years: { year: number; top: number; label: HTMLElement | null }[] = [];
  let currentYear = -1;

  const layout = () => {
    width = el.clientWidth;
    const cols = Math.max(3, Math.min(10, Math.floor(width / 170)));
    const tile = (width - gap * (cols - 1)) / cols;
    rows = [];
    years = [];
    let top = 0;
    for (const d of days) {
      const y = new Date(d.at).getFullYear();
      if (years[years.length - 1]?.year !== y) years.push({ year: y, top, label: null });
      rows.push({ top, height: headerHeight, header: dayLabel(d.at, d.place), day: d.photos });
      top += headerHeight;
      for (let i = 0; i < d.photos.length; i += cols) {
        rows.push({ top, height: tile, photos: d.photos.slice(i, i + cols) });
        top += tile + gap;
      }
    }
    total = top;
    el.style.height = `${top}px`;
    for (const node of live.values()) node.remove();
    live.clear();
    layoutRail();
    paint();
  };

  const jumpTo = (y: number) => {
    scroller.scrollTop = el.offsetTop + y;
  };

  const layoutRail = () => {
    if (!rail) return;
    rail.hidden = years.length < 2;
    currentYear = -1;
    let last = -1;
    const labels: Node[] = [];
    for (const y of years) {
      const at = total ? y.top / total : 0;
      y.label = null;
      if (last >= 0 && at - last < yearSpacing) continue;
      last = at;
      y.label = h(
        'button',
        {
          class: 'year',
          style: `top:${(at * 100).toFixed(2)}%`,
          onclick: (e: Event) => (e as MouseEvent).detail === 0 && jumpTo(y.top),
        },
        String(y.year),
      );
      labels.push(y.label);
    }
    rail.replaceChildren(marker, ...labels);
  };

  const paintRail = (viewTop: number) => {
    if (!rail || rail.hidden || !total) return;
    marker.style.top = `${((Math.max(0, viewTop) / total) * 100).toFixed(2)}%`;
    let i = 0;
    while (i + 1 < years.length && years[i + 1]!.top <= viewTop + headerHeight) i++;
    if (i === currentYear) return;
    for (const y of years) y.label?.classList.remove('on');
    currentYear = i;
    // A hidden label's year lights the nearest one shown above it.
    for (let k = i; k >= 0; k--) {
      if (years[k]!.label) {
        years[k]!.label!.classList.add('on');
        break;
      }
    }
  };

  if (rail) {
    const fromPointer = (e: PointerEvent) => {
      const r = rail.getBoundingClientRect();
      jumpTo(Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)) * total);
    };
    rail.addEventListener('pointerdown', (e) => {
      rail.setPointerCapture(e.pointerId);
      rail.classList.add('dragging');
      fromPointer(e);
    });
    rail.addEventListener('pointermove', (e) => rail.hasPointerCapture(e.pointerId) && fromPointer(e));
    const release = () => rail.classList.remove('dragging');
    rail.addEventListener('pointerup', release);
    rail.addEventListener('pointercancel', release);
  }

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

  const toggleDay = (day: Photo[]) => {
    if (!selection) return;
    const all = day.every((p) => selection.ids.has(p.id));
    for (const p of day) {
      if (all) selection.ids.delete(p.id);
      else selection.ids.add(p.id);
    }
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
      img,
      selection
        ? h('span', {
            class: 'pick-dot',
            onclick: (e: Event) => {
              e.stopPropagation();
              toggle(p, (e as MouseEvent).shiftKey);
            },
          })
        : null,
      p.isVideo ? h('span', { class: 'badge video' }, icon('play', { size: 14, filled: true })) : null,
      p.isLive && !p.isVideo ? h('span', { class: 'badge live' }, 'LIVE') : null,
      p.favorite ? h('span', { class: 'badge fav' }, icon('heart', { size: 14, filled: true })) : null,
      p.cloudOnly ? h('span', { class: 'badge cloud', title: t('cloudOnly') }, icon('cloud', { size: 14 })) : null,
    );
    const key = p.thumbKey ?? p.mediumKey;
    if (!key) {
      tile.classList.add('nothumb');
      return tile;
    }
    img.addEventListener('load', () => img.classList.add('in'), { once: true });
    img.addEventListener('error', () => tile.classList.add('nothumb'), { once: true });
    void thumbUrl(bucket, key, () => tile.isConnected).then((u) => {
      if (!u) return tile.classList.add('nothumb');
      img.src = u;
      // Already in the page's image memory: no fade for a tile scrolled back.
      if (img.complete && img.naturalWidth) img.classList.add('in');
    });
    return tile;
  };

  const headerFor = (r: Row) =>
    h(
      'div',
      { class: 'day', style: `top:${r.top}px` },
      h('span', {}, r.header!),
      selection && r.day
        ? h('button', { class: 'day-pick', onclick: () => toggleDay(r.day!) }, icon('check', { size: 16 }), t('selectDay'))
        : null,
    );

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
        ? headerFor(r)
        : h('div', { class: 'row', style: `top:${r.top}px;height:${r.height}px` }, ...r.photos!.map((p) => tileFor(p, r.height)));
      live.set(i, node);
      el.append(node);
    }
    paintRail(viewTop);
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
    rail,
    refresh,
    dispose: () => {
      scroller.removeEventListener('scroll', onScroll);
      resize.disconnect();
      if (frame) cancelAnimationFrame(frame);
      clear(el);
      rail?.remove();
    },
  };
}

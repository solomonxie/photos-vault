// Elements by hand. Text always goes in as textContent: captions and names
// come from the bucket, and nothing from there is ever parsed as HTML.

type Child = Node | string | null | undefined | false;
type Props = Record<string, string | number | boolean | EventListener | undefined> & {
  class?: string;
  style?: string;
};

export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props: Props = {},
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (v === undefined || v === false) continue;
    if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v as EventListener);
    else if (k === 'class') el.className = String(v);
    else if (v === true) el.setAttribute(k, '');
    else el.setAttribute(k, String(v));
  }
  for (const c of children) if (c !== null && c !== undefined && c !== false) el.append(c);
  return el;
}

export const clear = (el: Element) => {
  while (el.firstChild) el.firstChild.remove();
};

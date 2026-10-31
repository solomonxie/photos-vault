import type { Change, Engine } from '../sync/engine';
import { clear, h } from './dom';
import { t } from './i18n';

/// Every browser edit goes through here: applied and queued at once (one
/// IndexedDB transaction, see Engine.edit), sent ~2 s after the last one.
export class Editor {
  private timer = 0;

  constructor(
    private engine: Engine,
    private onChanged: () => void,
    private onSent: () => void,
  ) {
    // Leaving the page sends what's queued; whatever doesn't make it stays
    // in IndexedDB for the next visit.
    window.addEventListener('pagehide', () => void this.engine.flush().catch(() => {}));
  }

  async edit(changes: Change[]) {
    if (changes.length === 0) return;
    await this.engine.edit(changes);
    this.onChanged();
    clearTimeout(this.timer);
    this.timer = window.setTimeout(() => void this.send(), 2000);
  }

  async send() {
    try {
      await this.engine.flush();
    } finally {
      this.onSent();
    }
  }

  // Ops by name, so the screens never spell one out.

  set = (e: string, id: string, f: string, x: string | number | boolean | null) =>
    this.edit([{ e, id, o: 'set', f, x }]);

  bin = (ids: string[], at = Date.now()) =>
    this.edit(ids.map((id) => ({ e: 'asset', id, o: 'set', f: 'deleted_at', x: at })));

  restore = (ids: string[]) => this.edit(ids.map((id) => ({ e: 'asset', id, o: 'set', f: 'deleted_at', x: null })));

  favorite = (ids: string[], on: boolean) =>
    this.edit(ids.map((id) => ({ e: 'asset', id, o: 'set', f: 'is_favorite', x: on ? 1 : 0 })));

  member = (e: 'album' | 'person', owner: string, ids: string[], on: boolean) =>
    this.edit(ids.map((x) => ({ e, id: owner, o: on ? 'madd' : 'mrem', f: 'members', x })));

  tag = (id: string, tag: string, on: boolean) => this.edit([{ e: 'asset', id, o: on ? 'madd' : 'mrem', f: 'tags', x: tag }]);

  async newAlbum(name: string, photos: string[] = []): Promise<string> {
    const id = crypto.randomUUID();
    await this.edit([
      { e: 'album', id, o: 'add', x: { name, description: '', cover_local_id: null, deleted_at: null } },
      ...photos.map((x) => ({ e: 'album', id, o: 'madd' as const, f: 'members', x })),
    ]);
    return id;
  }

  async newPerson(name: string, photos: string[] = []): Promise<string> {
    const id = crypto.randomUUID();
    await this.edit([
      { e: 'person', id, o: 'add', x: { name, bio: '', deleted_at: null } },
      ...photos.map((x) => ({ e: 'person', id, o: 'madd' as const, f: 'members', x })),
    ]);
    return id;
  }
}

// ------------------------------------------------------------------ toast

let toastTimer = 0;

/// One line, one action, gone after 6 s.
export function toast(text: string, undo?: () => void) {
  document.querySelector('.toast')?.remove();
  const el = h(
    'div',
    { class: 'toast', role: 'status' },
    h('span', {}, text),
    undo
      ? h(
          'button',
          {
            class: 'link',
            onclick: () => {
              el.remove();
              undo();
            },
          },
          t('undo'),
        )
      : null,
  );
  document.body.append(el);
  clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => el.remove(), 6000);
}

// ----------------------------------------------------------------- dialogs

/// Find-or-create: a filtered list of [options] with "New … “typed”" first
/// when nothing matches exactly. Resolves to an option's id, `{create}`, or null.
export function pickOrCreate(
  title: string,
  options: { id: string; label: string; checked?: boolean }[],
  createLabel: (typed: string) => string,
): Promise<{ id: string } | { create: string } | null> {
  return new Promise((resolve) => {
    const input = h('input', { class: 'field', placeholder: t('findOrCreate'), autocomplete: 'off' });
    const list = h('div', { class: 'pick-list' });
    const dialog = h('dialog', { class: 'picker' }, h('div', { class: 'picker-title' }, title), input, list);
    let done = false;
    const finish = (v: { id: string } | { create: string } | null) => {
      if (done) return;
      done = true;
      dialog.close();
      dialog.remove();
      resolve(v);
    };
    const render = () => {
      clear(list);
      const q = input.value.trim();
      const shown = options.filter((o) => o.label.toLowerCase().includes(q.toLowerCase())).slice(0, 50);
      if (q && !options.some((o) => o.label.toLowerCase() === q.toLowerCase())) {
        list.append(h('button', { class: 'pick create', onclick: () => finish({ create: q }) }, `＋ ${createLabel(q)}`));
      }
      for (const o of shown) {
        list.append(h('button', { class: 'pick', onclick: () => finish({ id: o.id }) }, o.checked ? `✓ ${o.label}` : o.label));
      }
    };
    input.addEventListener('input', render);
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') (list.querySelector('button') as HTMLButtonElement | null)?.click();
    });
    dialog.addEventListener('close', () => finish(null));
    dialog.addEventListener('click', (e) => e.target === dialog && finish(null));
    document.body.append(dialog);
    render();
    dialog.showModal();
    input.focus();
  });
}

/// A one-field prompt, prefilled; null on cancel or an unchanged/empty value.
export function askText(title: string, value: string, multiline = false): Promise<string | null> {
  return new Promise((resolve) => {
    const input = multiline
      ? h('textarea', { class: 'field', rows: 4 })
      : h('input', { class: 'field', autocomplete: 'off' });
    input.value = value;
    const save = h('button', { class: 'primary', type: 'submit' }, t('save'));
    const cancel = h('button', { class: 'link', type: 'button' }, t('cancel'));
    const form = h('form', { method: 'dialog' }, h('div', { class: 'picker-title' }, title), input, h('div', { class: 'actions' }, cancel, save));
    const dialog = h('dialog', { class: 'picker' }, form);
    let result: string | null = null;
    form.addEventListener('submit', () => {
      const v = input.value.trim();
      result = v === value.trim() ? null : v;
    });
    cancel.addEventListener('click', () => dialog.close());
    dialog.addEventListener('close', () => {
      dialog.remove();
      resolve(result);
    });
    document.body.append(dialog);
    dialog.showModal();
    input.focus();
  });
}

export function confirmDanger(title: string, body: string, action: string): Promise<boolean> {
  return new Promise((resolve) => {
    const dialog = h(
      'dialog',
      { class: 'picker' },
      h('div', { class: 'picker-title' }, title),
      h('p', { class: 'muted' }, body),
      h(
        'div',
        { class: 'actions' },
        h('button', { class: 'link', onclick: () => dialog.close('no') }, t('cancel')),
        h('button', { class: 'primary danger', onclick: () => dialog.close('yes') }, action),
      ),
    );
    dialog.addEventListener('close', () => {
      dialog.remove();
      resolve(dialog.returnValue === 'yes');
    });
    document.body.append(dialog);
    dialog.showModal();
  });
}

import type { Bucket, Provider } from '../bucket/client';
import { h } from './dom';
import { type IconName, icon } from './icons';
import { ago, count, fullDate, lang, size, t } from './i18n';

export interface SyncStatus {
  lastSynced: number;
  waiting: number;
  conflicts: number;
  error: string;
  busy: boolean;
}

export interface SettingsContext {
  bucket: Bucket;
  pullEvery: number;
  status: () => SyncStatus;
  syncNow: () => Promise<void>;
  disconnect: () => Promise<void>;
}

const providerNames: Record<Provider, string> = { s3: 'AWS S3', cos: 'Tencent COS', oss: 'Alibaba OSS' };

const masked = (id: string) => (id.length > 8 ? `${id.slice(0, 4)}••••${id.slice(-4)}` : '••••');

const row = (label: string, value: Node | string, hint?: string) =>
  h(
    'div',
    { class: 'set-row' },
    h('div', { class: 'set-label' }, label, hint ? h('div', { class: 'set-hint' }, hint) : null),
    h('div', { class: 'set-value' }, value),
  );

const section = (id: string, name: IconName, title: string, ...rows: (Node | null)[]) =>
  h(
    'section',
    { class: 'set-section', id: `settings-${id}` },
    h('h2', { class: 'set-title' }, icon(name), title),
    h('div', { class: 'set-card' }, ...rows),
  );

/// Settings: the connection, sync, what this computer keeps, and about.
/// `refresh` redraws the sync rows after every pull.
export function settingsView(ctx: SettingsContext): { el: HTMLElement; refresh: () => void } {
  const c = ctx.bucket.c;

  const testResult = h('span', { class: 'set-result', role: 'status' });
  const test = h('button', { class: 'btn' }, t('settingsTest'));
  test.addEventListener('click', async () => {
    test.disabled = true;
    testResult.className = 'set-result';
    testResult.textContent = t('settingsTesting');
    try {
      const ms = await ctx.bucket.ping();
      testResult.className = 'set-result ok';
      testResult.textContent = t('settingsTestOk', count(ms));
    } catch (e) {
      testResult.className = 'set-result error';
      testResult.textContent = e instanceof Error ? e.message : String(e);
    } finally {
      test.disabled = false;
    }
  });

  const cloud = section(
    'cloud',
    'cloud',
    t('settingsCloud'),
    row(t('settingsProvider'), providerNames[c.provider]),
    row(t('settingsBucket'), c.bucket),
    row(t('settingsRegion'), c.region || '—'),
    row(t('settingsEndpoint'), h('code', {}, ctx.bucket.host)),
    row(t('settingsPrefix'), c.prefix ? h('code', {}, c.prefix) : t('settingsPrefixRoot')),
    row(t('settingsKeyId'), h('code', {}, masked(c.accessKeyId)), t('settingsSecretNote')),
    h(
      'div',
      { class: 'set-actions' },
      test,
      testResult,
      h('span', { class: 'spacer' }),
      h('button', { class: 'btn danger', onclick: () => void ctx.disconnect() }, t('settingsDisconnect')),
    ),
  );

  const lastPull = h('span');
  const waiting = h('span');
  const conflicts = h('span');
  const errorRow = h('div', { class: 'set-row' });
  const syncNow = h('button', { class: 'btn' }, icon('sync', { size: 16 }), t('syncNow'));
  syncNow.addEventListener('click', () => void ctx.syncNow());

  const sync = section(
    'sync',
    'sync',
    t('settingsSync'),
    row(t('settingsLastPull'), lastPull),
    row(t('settingsInterval'), t('settingsIntervalValue', count(Math.round(ctx.pullEvery / 1000)))),
    row(t('settingsWaiting'), waiting),
    row(t('settingsConflicts'), conflicts),
    errorRow,
    h('div', { class: 'set-actions' }, syncNow),
  );

  const metadata = h('span', {}, '—');
  void navigator.storage
    ?.estimate?.()
    .then((e) => {
      if (e.usage !== undefined) metadata.textContent = size(e.usage);
    })
    .catch(() => {});

  const storage = section(
    'storage',
    'shield',
    t('settingsStorage'),
    h('div', { class: 'set-note' }, t('settingsNoMedia')),
    row(t('settingsMetadata'), metadata, t('settingsMetadataHint')),
  );

  const about = section(
    'about',
    'info',
    t('settingsAbout'),
    row(t('settingsVersion'), typeof chrome !== 'undefined' && chrome.runtime?.getManifest ? chrome.runtime.getManifest().version : '—'),
    row(t('settingsLanguage'), new Intl.DisplayNames([lang()], { type: 'language' }).of(lang()) ?? lang(), t('settingsLanguageHint')),
  );

  const refresh = () => {
    const s = ctx.status();
    lastPull.textContent = s.lastSynced ? `${ago(s.lastSynced)} · ${fullDate(s.lastSynced)}` : t('statusNever');
    waiting.textContent = count(s.waiting);
    conflicts.textContent = count(s.conflicts);
    syncNow.disabled = s.busy;
    syncNow.classList.toggle('busy', s.busy);
    errorRow.hidden = !s.error;
    errorRow.replaceChildren(h('div', { class: 'set-label' }, t('settingsLastError')), h('div', { class: 'set-value error' }, s.error));
  };
  refresh();

  return { el: h('div', { class: 'settings' }, cloud, sync, storage, about), refresh };
}

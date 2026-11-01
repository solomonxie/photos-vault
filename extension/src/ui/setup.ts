import { Bucket, BucketError, type Connection, type Provider } from '../bucket/client';
import {
  detectS3Region,
  dropDraft,
  keepDraft,
  loadDrafts,
  normalizePrefix,
  originsFor,
  parsePaste,
  saveConnection,
} from '../connection';
import { clear, h } from './dom';
import { t } from './i18n';

/// Setup: one bucket, proved by a real listing before anything is stored.
/// See docs/design/cloud-sync/uiux/setup.md.
export function setupView(initial: Partial<Connection>, onConnected: (c: Connection) => void): HTMLElement {
  let provider: Provider = initial.provider ?? 's3';
  const field = (name: string, placeholder: string, value = '', type = 'text') =>
    h('input', {
      class: 'field',
      name,
      type,
      placeholder,
      value,
      autocomplete: 'off',
      spellcheck: 'false',
      autocapitalize: 'off',
    });
  const bucket = field('bucket', t('setupBucket'), initial.bucket);
  const keyId = field('keyId', t('setupKeyId'), initial.accessKeyId);
  const secret = field('secret', t('setupSecret'), initial.secretAccessKey, 'password');
  const prefix = field('prefix', t('setupPrefix'), initial.prefix);
  const region = field('region', t('setupRegion'), initial.region);
  const status = h('div', { class: 'setup-status', role: 'status' });
  const connect = h('button', { class: 'primary', type: 'submit' }, t('setupConnect'));

  const providers = h('div', { class: 'segmented', role: 'radiogroup' });
  const regionRow = h('div', { class: 'region-row' }, region);
  const renderProviders = () => {
    clear(providers);
    for (const [p, label] of [
      ['s3', 'AWS S3'],
      ['cos', 'Tencent COS'],
      ['oss', 'Alibaba OSS'],
    ] as const) {
      providers.append(
        h(
          'button',
          {
            type: 'button',
            class: p === provider ? 'on' : '',
            onclick: () => {
              provider = p;
              renderProviders();
            },
          },
          label,
        ),
      );
    }
    // S3's region is detected; COS and OSS name theirs.
    regionRow.hidden = provider === 's3';
  };
  renderProviders();

  const fields = h('div', { class: 'fields' }, bucket, keyId, secret, prefix, regionRow);
  const paste = h('textarea', {
    class: 'paste',
    rows: 5,
    spellcheck: 'false',
    placeholder: 'bucket: my-photos\nprefix: vault/\naccess_key_id: AKIA…\nsecret_access_key: …',
  });
  paste.addEventListener('input', () => {
    const got = parsePaste(paste.value);
    if (got.bucket) bucket.value = got.bucket;
    if (got.prefix) prefix.value = got.prefix;
    if (got.accessKeyId) keyId.value = got.accessKeyId;
    if (got.secretAccessKey) secret.value = got.secretAccessKey;
    if (got.region) region.value = got.region;
  });
  const pasteBox = h('div', { class: 'paste-box', hidden: true }, paste, h('p', { class: 'hint' }, t('setupPasteHint')));
  const pasteToggle = h('button', { type: 'button', class: 'link' }, t('setupPaste'));
  pasteToggle.addEventListener('click', () => {
    const showing = !pasteBox.hidden;
    pasteBox.hidden = showing;
    fields.hidden = !showing;
    pasteToggle.textContent = showing ? t('setupPaste') : t('setupBackToFields');
  });

  const drafts = h('div', { class: 'drafts' });
  const fill = (d: Connection) => {
    provider = d.provider;
    renderProviders();
    bucket.value = d.bucket;
    keyId.value = d.accessKeyId;
    secret.value = d.secretAccessKey;
    prefix.value = d.prefix;
    region.value = d.region;
  };
  const renderDrafts = async () => {
    clear(drafts);
    const list = await loadDrafts();
    if (list.length === 0) return;
    drafts.append(h('div', { class: 'section-title' }, t('setupDrafts')));
    for (const d of list) {
      drafts.append(
        h(
          'div',
          { class: 'draft' },
          h('span', {}, `${d.bucket}/${d.prefix} · ${d.accessKeyId.slice(0, 6)}…`),
          h('button', { type: 'button', class: 'link', onclick: () => fill(d) }, t('setupFill')),
          h('button', { type: 'button', class: 'link', onclick: () => void dropDraft(d).then(renderDrafts) }, '✕'),
        ),
      );
    }
  };
  void renderDrafts();

  const say = (text: string, error = false) => {
    status.textContent = text;
    status.className = error ? 'setup-status error' : 'setup-status';
  };

  const form = h(
    'form',
    { class: 'setup' },
    h('h1', {}, t('name')),
    h('p', { class: 'subtitle' }, t('description')),
    h('div', { class: 'group-head' }, h('span', { class: 'section-title' }, t('setupBucketHeading')), pasteToggle),
    providers,
    fields,
    pasteBox,
    h('p', { class: 'hint' }, t('setupScopeHint')),
    status,
    connect,
    drafts,
  );

  form.addEventListener('submit', (ev) => {
    ev.preventDefault();
    const c: Connection = {
      provider,
      bucket: bucket.value.trim(),
      accessKeyId: keyId.value.trim(),
      secretAccessKey: secret.value.trim(),
      prefix: normalizePrefix(prefix.value),
      region: region.value.trim().toLowerCase(),
    };
    // Asked first, inside the click: Chrome grants host access only to a gesture.
    const asked = chrome.permissions.request({ origins: originsFor(c) });
    void (async () => {
      connect.disabled = true;
      try {
        say(t('setupAsking', c.bucket));
        if (!(await asked)) {
          say(t('setupDenied'), true);
          return;
        }
        await keepDraft(c);
        if (provider === 's3') {
          say(t('setupDetecting'));
          const found = await detectS3Region(c.bucket);
          if (!found) {
            say(t('setupNoSuchBucket', c.bucket), true);
            return;
          }
          c.region = found;
          region.value = found;
          // Its own host, not known when the click asked: one more click.
          if (!(await chrome.permissions.contains({ origins: originsFor(c) }))) {
            say(t('setupRegionFound', found));
            return;
          }
        }
        say(t('setupChecking'));
        const b = new Bucket(c);
        const { objects, prefixes } = await b.list('sync/', { delimiter: '/', max: 1 });
        await saveConnection(c);
        await dropDraft(c);
        if (objects.length === 0 && prefixes.length === 0) say(t('setupNoLibrary', `${c.bucket}/${c.prefix}`));
        onConnected(c);
      } catch (e) {
        const code = e instanceof BucketError ? e.message : String(e);
        say(code, true);
      } finally {
        connect.disabled = false;
        void renderDrafts();
      }
    })();
  });
  return form;
}

export function waitingView(onChange: () => void): HTMLElement {
  return h(
    'div',
    { class: 'waiting' },
    h('div', { class: 'spinner' }),
    h('h2', {}, t('waitingTitle')),
    h('p', {}, t('waitingBody')),
    h('p', { class: 'hint' }, t('waitingPolling')),
    h('button', { class: 'link', onclick: onChange }, t('waitingChange')),
  );
}

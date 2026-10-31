import type { Connection, Provider } from './bucket/client';

// The bucket connection, in chrome.storage.local only: `.sync` would carry
// the secret to every machine signed in to the same Google account.

const key = 'connection';
const draftsKey = 'drafts';

export const loadConnection = async (): Promise<Connection | null> =>
  ((await chrome.storage.local.get(key))[key] as Connection | undefined) ?? null;

export const saveConnection = (c: Connection) => chrome.storage.local.set({ [key]: c });

export const forgetConnection = () => chrome.storage.local.remove(key);

export const normalizePrefix = (p: string) => {
  const t = p.trim().replace(/^\/+/, '');
  return t === '' || t.endsWith('/') ? t : `${t}/`;
};

export const originFor = (p: Provider) =>
  ({ s3: 'https://*.amazonaws.com/*', cos: 'https://*.myqcloud.com/*', oss: 'https://*.aliyuncs.com/*' })[p];

// Drafts: every attempt, keyed by bucket + prefix + key id, so a failed
// Connect never means retyping a secret. Dropped once one succeeds.

export type Draft = Connection;

const draftId = (d: Draft) => `${d.provider}|${d.bucket}|${d.prefix}|${d.accessKeyId}`;

export const loadDrafts = async (): Promise<Draft[]> =>
  ((await chrome.storage.local.get(draftsKey))[draftsKey] as Draft[] | undefined) ?? [];

export async function keepDraft(d: Draft) {
  const rest = (await loadDrafts()).filter((x) => draftId(x) !== draftId(d));
  await chrome.storage.local.set({ [draftsKey]: [d, ...rest].slice(0, 5) });
}

export async function dropDraft(d: Draft) {
  await chrome.storage.local.set({ [draftsKey]: (await loadDrafts()).filter((x) => draftId(x) !== draftId(d)) });
}

/// A pasted note, `.env` or console output → the fields it names. Liberal:
/// `:` or `=`, `export `, quotes, the spellings people have. Split on the
/// first separator only, so a base64 secret keeps its `/`, `+` and `=`.
/// Unknown keys are ignored; an empty value fills nothing.
export function parsePaste(text: string): Partial<Connection> {
  const out: Partial<Connection> = {};
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim().replace(/^export\s+/i, '').replace(/,$/, '');
    const m = /^["']?([A-Za-z _-]+?)["']?\s*[:=]\s*(.*)$/.exec(line);
    if (!m) continue;
    const name = m[1]!.toLowerCase().replace(/[\s_-]/g, '');
    const value = m[2]!.trim().replace(/^["']|["']$/g, '');
    if (!value) continue;
    if (['bucket', 'bucketname', 'awsbucket', 's3bucket'].includes(name)) out.bucket = value;
    else if (['prefix', 'keyprefix', 'path'].includes(name)) out.prefix = value;
    else if (['accesskeyid', 'awsaccesskeyid', 'accesskey', 'secretid', 'keyid'].includes(name)) out.accessKeyId = value;
    else if (['secretaccesskey', 'awssecretaccesskey', 'secretkey', 'secret', 'accesskeysecret'].includes(name))
      out.secretAccessKey = value;
    else if (['region', 'awsregion', 'awsdefaultregion'].includes(name)) out.region = value;
  }
  return out;
}

/// S3 says where a bucket lives on an unsigned HEAD, even when it says no.
export async function detectS3Region(bucket: string): Promise<string | null> {
  try {
    const res = await fetch(`https://${bucket}.s3.amazonaws.com/`, { method: 'HEAD' });
    return res.headers.get('x-amz-bucket-region');
  } catch {
    return null;
  }
}

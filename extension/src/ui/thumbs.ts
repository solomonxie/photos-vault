import type { Bucket } from '../bucket/client';

// Media is never kept on this computer: every thumbnail and view is a
// presigned URL set straight as a src, reused while it has time left so the
// page's own image memory serves a tile scrolled back into view.

const lifetime = 3600;
const margin = 60_000;
const signed = new Map<string, { url: string; until: number }>();

async function signedUrl(bucket: Bucket, key: string, download?: string): Promise<string> {
  const id = `${key}|${download ?? ''}`;
  const have = signed.get(id);
  if (have && have.until > Date.now() + margin) return have.url;
  const url = await bucket.presignGet(key, lifetime, download);
  signed.set(id, { url, until: Date.now() + lifetime * 1000 });
  return url;
}

export const thumbUrl = (bucket: Bucket, key: string): Promise<string | null> => signedUrl(bucket, key).catch(() => null);

export const viewUrl = (bucket: Bucket, key: string, download?: string): Promise<string> => signedUrl(bucket, key, download);

/// What an earlier version cached in the Cache API.
export const purgeMediaCache = () => (typeof caches === 'undefined' ? Promise.resolve(false) : caches.delete('pv-thumbs-v1').catch(() => false));

import type { Bucket } from '../bucket/client';

// Thumbnails by object key: the Cache API first (a presigned URL changes
// every time, so the HTTP cache never hits), then the bucket, cached on arrival.

const cacheName = 'pv-thumbs-v1';
const cacheUrl = (key: string) => `https://photos-vault.invalid/${encodeURIComponent(key)}`;

const urls = new Map<string, Promise<string | null>>();

export function thumbUrl(bucket: Bucket, key: string): Promise<string | null> {
  let p = urls.get(key);
  if (!p) {
    p = load(bucket, key).catch(() => {
      urls.delete(key);
      return null;
    });
    urls.set(key, p);
  }
  return p;
}

async function load(bucket: Bucket, key: string): Promise<string | null> {
  const cache = await caches.open(cacheName);
  const hit = await cache.match(cacheUrl(key));
  if (hit) return URL.createObjectURL(await hit.blob());
  const res = await fetch(await bucket.presignGet(key, 3600));
  if (!res.ok) return null;
  const blob = await res.blob();
  await cache.put(cacheUrl(key), new Response(blob, { headers: { 'content-type': blob.type } }));
  return URL.createObjectURL(blob);
}

/// Presigned URLs for full-size views, reused while they have time left.
const signed = new Map<string, { url: string; until: number }>();

export async function viewUrl(bucket: Bucket, key: string, download?: string): Promise<string> {
  const id = `${key}|${download ?? ''}`;
  const have = signed.get(id);
  if (have && have.until > Date.now() + 60_000) return have.url;
  const url = await bucket.presignGet(key, 3600, download);
  signed.set(id, { url, until: Date.now() + 3_600_000 });
  return url;
}

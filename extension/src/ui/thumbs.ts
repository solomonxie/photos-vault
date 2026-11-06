import type { Bucket } from '../bucket/client';

// Media is never kept on this computer: views are presigned URLs set
// straight as a src, thumbnails live in this tab's memory only.

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

/// Thumbnails held in this tab's memory only, newest kept: a tile scrolled
/// back into view (the grid rebuilds rows as it scrolls) isn't fetched again.
/// Nothing is written to disk; closing the tab drops them all.
const keep = 4000;
const parallel = 8;
const thumbs = new Map<string, Promise<string | null>>();
const queue: (() => void)[] = [];
let running = 0;

const pump = () => {
  while (running < parallel && queue.length) {
    running++;
    queue.pop()!();
  }
};

/// Latest asked first: the tiles just scrolled to, not the ones flown past.
const queued = <T>(job: () => Promise<T>): Promise<T> =>
  new Promise<T>((resolve, reject) => {
    queue.push(() =>
      job()
        .then(resolve, reject)
        .finally(() => {
          running--;
          pump();
        }),
    );
    // After the caller's tile is in the page, so [wanted] sees it there.
    queueMicrotask(pump);
  });

const evict = () => {
  for (const [key, url] of thumbs) {
    if (thumbs.size <= keep) break;
    thumbs.delete(key);
    void url.then((u) => u && URL.revokeObjectURL(u));
  }
};

/// [wanted]: checked when its turn comes, so a tile already scrolled away
/// costs nothing.
export function thumbUrl(bucket: Bucket, key: string, wanted: () => boolean = () => true): Promise<string | null> {
  const have = thumbs.get(key);
  if (have) {
    thumbs.delete(key);
    thumbs.set(key, have);
    return have;
  }
  const p = queued(async () => {
    if (!wanted()) return undefined;
    const res = await fetch(await signedUrl(bucket, key));
    return res.ok ? URL.createObjectURL(await res.blob()) : null;
  }).then(
    (u) => {
      if (u === undefined) thumbs.delete(key);
      return u ?? null;
    },
    () => {
      thumbs.delete(key);
      return null;
    },
  );
  thumbs.set(key, p);
  evict();
  return p;
}

export const viewUrl = (bucket: Bucket, key: string, download?: string): Promise<string> => signedUrl(bucket, key, download);

/// What an earlier version cached in the Cache API.
export const purgeMediaCache = () => (typeof caches === 'undefined' ? Promise.resolve(false) : caches.delete('pv-thumbs-v1').catch(() => false));

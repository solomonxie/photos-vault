import type { ListedObject } from '../src/bucket/client';
import type { LogBucket } from '../src/sync/engine';

/// An in-memory bucket with S3's write-once semantics and server LastModified.
export class FakeBucket implements LogBucket {
  objects = new Map<string, { body: Uint8Array; lastModified: number }>();
  clock = 1_793_414_025_000;
  failNextPutAfterWrite = false;

  now() {
    return (this.clock += 10);
  }

  async list(prefix: string, opts: { startAfter?: string; delimiter?: string } = {}) {
    const keys = [...this.objects.keys()].filter((k) => k.startsWith(prefix) && (!opts.startAfter || k > opts.startAfter)).sort();
    if (opts.delimiter) {
      const prefixes = new Set<string>();
      for (const k of keys) {
        const rest = k.slice(prefix.length);
        const i = rest.indexOf(opts.delimiter);
        if (i >= 0) prefixes.add(prefix + rest.slice(0, i + 1));
      }
      return { objects: [], prefixes: [...prefixes].sort() };
    }
    const objects: ListedObject[] = keys.map((key) => ({
      key,
      size: this.objects.get(key)!.body.length,
      etag: '',
      lastModified: this.objects.get(key)!.lastModified,
    }));
    return { objects, prefixes: [] };
  }

  async get(key: string) {
    const o = this.objects.get(key);
    if (!o) throw new Error(`404 ${key}`);
    return o.body;
  }

  async put(key: string, body: Uint8Array) {
    this.objects.set(key, { body, lastModified: this.now() });
  }

  async putOnce(key: string, body: Uint8Array) {
    const there = this.objects.get(key);
    if (there) {
      const same = there.body.length === body.length && there.body.every((b, i) => b === body[i]);
      return same ? ('exists-same' as const) : ('collision' as const);
    }
    this.objects.set(key, { body, lastModified: this.now() });
    if (this.failNextPutAfterWrite) {
      this.failNextPutAfterWrite = false;
      throw new Error('network dropped after the PUT landed');
    }
    return 'written' as const;
  }
}

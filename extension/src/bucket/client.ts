import {
  type Credentials,
  canonicalQuery,
  emptySha256,
  presign,
  sha256Hex,
  signHeaders,
  unsignedPayload,
  uriEncode,
} from './sigv4';

export type Provider = 's3' | 'cos' | 'oss';

export interface Connection extends Credentials {
  provider: Provider;
  bucket: string;
  /// '' or ending in '/'; same as the phone target's prefix.
  prefix: string;
}

/// Same hosts as lib/settings/bucket_endpoint.dart.
export const bucketHost = (c: Pick<Connection, 'provider' | 'bucket' | 'region'>) =>
  ({
    s3: `${c.bucket}.s3.${c.region}.amazonaws.com`,
    cos: `${c.bucket}.cos.${c.region}.myqcloud.com`,
    oss: `${c.bucket}.s3.oss-${c.region}.aliyuncs.com`,
  })[c.provider];

/// Header that makes a PUT fail instead of overwrite.
const writeOnceHeader: Record<Provider, [string, string]> = {
  s3: ['if-none-match', '*'],
  cos: ['x-cos-forbid-overwrite', 'true'],
  oss: ['x-oss-forbid-overwrite', 'true'],
};

export interface ListedObject {
  key: string;
  size: number;
  etag: string;
  lastModified: number;
}

export class BucketError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(`${code || status}: ${message}`);
  }
}

const tag = (xml: string, name: string) => new RegExp(`<${name}>([\\s\\S]*?)</${name}>`).exec(xml)?.[1];
const unescapeXml = (s: string) =>
  s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');

/// No DOMParser in a service worker: the few S3 XML shapes we read, by regex.
export const parseList = (xml: string) => ({
  objects: [...xml.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)].map(
    ([, c]): ListedObject => ({
      key: unescapeXml(tag(c!, 'Key') ?? ''),
      size: Number(tag(c!, 'Size') ?? 0),
      etag: unescapeXml(tag(c!, 'ETag') ?? '').replace(/"/g, ''),
      lastModified: Date.parse(tag(c!, 'LastModified') ?? ''),
    }),
  ),
  prefixes: [...xml.matchAll(/<CommonPrefixes>\s*<Prefix>([\s\S]*?)<\/Prefix>/g)].map(([, p]) => unescapeXml(p!)),
  truncated: tag(xml, 'IsTruncated') === 'true',
  next: tag(xml, 'NextContinuationToken'),
});

export class Bucket {
  /// Bucket time minus local time, from the last response's Date header.
  clockOffset = 0;

  constructor(readonly c: Connection) {}

  get host() {
    return bucketHost(this.c);
  }

  /// Bucket-relative key → full key under the connection's prefix. A key
  /// already under it is left alone: records carry full keys, as the
  /// phone stores them.
  full(key: string) {
    return key.startsWith(this.c.prefix) ? key : this.c.prefix + key;
  }

  now() {
    return Date.now() + this.clockOffset;
  }

  private async send(
    method: string,
    key: string,
    opts: { query?: Record<string, string>; headers?: Record<string, string>; body?: Uint8Array | Blob; hash?: string } = {},
  ): Promise<Response> {
    const query = opts.query ?? {};
    const path = `/${key}`;
    const headers = await signHeaders(this.c, {
      method,
      host: this.host,
      path,
      query,
      headers: opts.headers,
      payloadHash: opts.hash ?? (opts.body ? unsignedPayload : emptySha256),
    }, new Date(this.now()));
    // The URL must carry exactly the encoding that was signed.
    const qs = canonicalQuery(query);
    const res = await fetch(`https://${this.host}${uriEncode(path, true)}${qs ? `?${qs}` : ''}`, {
      method,
      headers,
      body: opts.body as BodyInit | undefined,
    });
    const date = res.headers.get('date');
    if (date) this.clockOffset = Date.parse(date) - Date.now();
    return res;
  }

  private async fail(res: Response): Promise<never> {
    const body = await res.text().catch(() => '');
    throw new BucketError(res.status, tag(body, 'Code') ?? '', tag(body, 'Message') ?? res.statusText);
  }

  async list(prefix: string, opts: { startAfter?: string; delimiter?: string; max?: number } = {}) {
    const out: ListedObject[] = [];
    const prefixes: string[] = [];
    let token: string | undefined;
    do {
      const query: Record<string, string> = { 'list-type': '2', prefix: this.full(prefix) };
      if (opts.startAfter) query['start-after'] = this.full(opts.startAfter);
      if (opts.delimiter) query.delimiter = opts.delimiter;
      if (token) query['continuation-token'] = token;
      const res = await this.send('GET', '', { query });
      if (!res.ok) await this.fail(res);
      const page = parseList(await res.text());
      out.push(...page.objects.map((o) => ({ ...o, key: o.key.slice(this.c.prefix.length) })));
      prefixes.push(...page.prefixes.map((p) => p.slice(this.c.prefix.length)));
      token = page.truncated ? page.next : undefined;
    } while (token && (opts.max === undefined || out.length < opts.max));
    return { objects: out, prefixes };
  }

  /// One signed listing of at most one key: proves reach, credentials and permission.
  async ping(): Promise<number> {
    const started = performance.now();
    const res = await this.send('GET', '', { query: { 'list-type': '2', prefix: this.full('sync/'), 'max-keys': '1' } });
    if (!res.ok) await this.fail(res);
    return Math.round(performance.now() - started);
  }

  async get(key: string): Promise<Uint8Array> {
    const res = await this.send('GET', this.full(key));
    if (!res.ok) await this.fail(res);
    return new Uint8Array(await res.arrayBuffer());
  }

  /// Present / absent / thrown: only a 404 is absent.
  async head(key: string): Promise<{ size: number; etag: string } | null> {
    const res = await this.send('HEAD', this.full(key));
    if (res.status === 404) return null;
    if (!res.ok) throw new BucketError(res.status, '', res.statusText);
    return { size: Number(res.headers.get('content-length') ?? 0), etag: (res.headers.get('etag') ?? '').replace(/"/g, '') };
  }

  async put(key: string, body: Uint8Array | Blob, contentType = 'application/octet-stream') {
    const res = await this.send('PUT', this.full(key), { body, headers: { 'content-type': contentType } });
    if (!res.ok) await this.fail(res);
  }

  /// Never overwrites. 'exists-same' = an earlier try landed; 'collision' = another writer's bytes.
  async putOnce(key: string, body: Uint8Array): Promise<'written' | 'exists-same' | 'collision'> {
    const [name, value] = writeOnceHeader[this.c.provider];
    const hash = await sha256Hex(body);
    const res = await this.send('PUT', this.full(key), {
      body,
      hash,
      headers: { [name]: value, 'content-type': 'application/gzip' },
    });
    if (res.ok) return 'written';
    if (res.status !== 412 && res.status !== 409) await this.fail(res);
    const there = await this.get(key);
    return (await sha256Hex(there)) === hash ? 'exists-same' : 'collision';
  }

  /// `no-store`: media is shown, never written to the browser's disk cache.
  presignGet(key: string, expiresSeconds = 900, download?: string) {
    const query: Record<string, string> = { 'response-cache-control': 'no-store' };
    if (download) query['response-content-disposition'] = `attachment; filename="${download}"`;
    return presign(
      this.c,
      {
        method: 'GET',
        host: this.host,
        path: `/${this.full(key)}`,
        query,
      },
      expiresSeconds,
      new Date(this.now()),
    );
  }

  async multipartStart(key: string, contentType: string): Promise<string> {
    const res = await this.send('POST', this.full(key), { query: { uploads: '' }, headers: { 'content-type': contentType } });
    if (!res.ok) await this.fail(res);
    return tag(await res.text(), 'UploadId') ?? '';
  }

  async multipartPart(key: string, uploadId: string, part: number, body: Blob): Promise<string> {
    const res = await this.send('PUT', this.full(key), { query: { partNumber: String(part), uploadId }, body });
    if (!res.ok) await this.fail(res);
    return res.headers.get('etag') ?? '';
  }

  async multipartComplete(key: string, uploadId: string, etags: string[]) {
    const xml = `<CompleteMultipartUpload>${etags
      .map((e, i) => `<Part><PartNumber>${i + 1}</PartNumber><ETag>${e}</ETag></Part>`)
      .join('')}</CompleteMultipartUpload>`;
    const body = new TextEncoder().encode(xml);
    const res = await this.send('POST', this.full(key), { query: { uploadId }, body, hash: await sha256Hex(body) });
    if (!res.ok) await this.fail(res);
    const text = await res.text();
    // S3 can answer 200 with an <Error> body here.
    if (text.includes('<Error>')) throw new BucketError(200, tag(text, 'Code') ?? '', tag(text, 'Message') ?? '');
  }
}

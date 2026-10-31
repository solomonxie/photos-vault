// AWS SigV4 for S3 and the S3 APIs of COS and OSS, over SubtleCrypto.
// The same signing lib/upload/signing.dart does through aws_signature_v4.

export interface Credentials {
  accessKeyId: string;
  secretAccessKey: string;
  region: string;
}

const enc = new TextEncoder();
export const emptySha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
export const unsignedPayload = 'UNSIGNED-PAYLOAD';

const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');

export const sha256Hex = async (data: Uint8Array | string) =>
  hex(await crypto.subtle.digest('SHA-256', typeof data === 'string' ? enc.encode(data) : (data as BufferSource)));

const hmac = async (key: ArrayBuffer | Uint8Array, msg: string) =>
  crypto.subtle.sign(
    'HMAC',
    await crypto.subtle.importKey('raw', key as BufferSource, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']),
    enc.encode(msg),
  );

/// RFC 3986 encoding as SigV4 wants it; `/` kept in paths.
export const uriEncode = (s: string, keepSlash = false) =>
  [...enc.encode(s)]
    .map((b) => {
      const c = String.fromCharCode(b);
      if (/[A-Za-z0-9\-._~]/.test(c) || (keepSlash && c === '/')) return c;
      return `%${b.toString(16).toUpperCase().padStart(2, '0')}`;
    })
    .join('');

export const amzDate = (d: Date) => d.toISOString().replace(/[:-]|\.\d{3}/g, '');

export const canonicalQuery = (q: Record<string, string>) =>
  Object.keys(q)
    .sort()
    .map((k) => `${uriEncode(k)}=${uriEncode(q[k]!)}`)
    .join('&');

const signingKey = async (c: Credentials, day: string) => {
  const kDate = await hmac(enc.encode(`AWS4${c.secretAccessKey}`), day);
  const kRegion = await hmac(kDate, c.region);
  const kService = await hmac(kRegion, 's3');
  return hmac(kService, 'aws4_request');
};

interface Canonical {
  method: string;
  host: string;
  path: string;
  query: Record<string, string>;
  headers: Record<string, string>;
  payloadHash: string;
}

const signature = async (c: Credentials, req: Canonical, when: string) => {
  const day = when.slice(0, 8);
  const names = Object.keys(req.headers)
    .map((h) => h.toLowerCase())
    .sort();
  const lower = Object.fromEntries(Object.entries(req.headers).map(([k, v]) => [k.toLowerCase(), v.trim()]));
  const canonical = [
    req.method,
    uriEncode(req.path, true),
    canonicalQuery(req.query),
    names.map((n) => `${n}:${lower[n]}\n`).join(''),
    names.join(';'),
    req.payloadHash,
  ].join('\n');
  const scope = `${day}/${c.region}/s3/aws4_request`;
  const toSign = ['AWS4-HMAC-SHA256', when, scope, await sha256Hex(canonical)].join('\n');
  return { sig: hex(await hmac(await signingKey(c, day), toSign)), scope, signed: names.join(';') };
};

/// Headers to send for a request signed in the Authorization header.
export async function signHeaders(
  c: Credentials,
  req: Omit<Canonical, 'headers'> & { headers?: Record<string, string> },
  now = new Date(),
): Promise<Record<string, string>> {
  const when = amzDate(now);
  const headers = {
    ...req.headers,
    host: req.host,
    'x-amz-date': when,
    'x-amz-content-sha256': req.payloadHash,
  };
  const { sig, scope, signed } = await signature(c, { ...req, headers }, when);
  const { host: _host, ...rest } = headers;
  return {
    ...rest,
    authorization: `AWS4-HMAC-SHA256 Credential=${c.accessKeyId}/${scope},SignedHeaders=${signed},Signature=${sig}`,
  };
}

/// A query-signed URL for <img>/<video>/download: nothing to set but the src.
export async function presign(
  c: Credentials,
  req: { method: string; host: string; path: string; query?: Record<string, string> },
  expiresSeconds = 900,
  now = new Date(),
): Promise<string> {
  const when = amzDate(now);
  const query: Record<string, string> = {
    ...req.query,
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': `${c.accessKeyId}/${when.slice(0, 8)}/${c.region}/s3/aws4_request`,
    'X-Amz-Date': when,
    'X-Amz-Expires': String(expiresSeconds),
    'X-Amz-SignedHeaders': 'host',
  };
  const { sig } = await signature(
    c,
    { method: req.method, host: req.host, path: req.path, query, headers: { host: req.host }, payloadHash: unsignedPayload },
    when,
  );
  return `https://${req.host}${uriEncode(req.path, true)}?${canonicalQuery(query)}&X-Amz-Signature=${sig}`;
}

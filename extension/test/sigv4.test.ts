import { expect, test } from 'vitest';
import { emptySha256, presign, signHeaders } from '../src/bucket/sigv4';

// The worked examples in AWS's "Signature Calculations for the Authorization Header"
// and "Authenticating Requests: Using Query Parameters" (S3 API reference).
const creds = {
  accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
  secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
  region: 'us-east-1',
};
const when = new Date('2013-05-24T00:00:00Z');

test('GET object, header signing', async () => {
  const h = await signHeaders(
    creds,
    { method: 'GET', host: 'examplebucket.s3.amazonaws.com', path: '/test.txt', query: {}, headers: { range: 'bytes=0-9' }, payloadHash: emptySha256 },
    when,
  );
  expect(h.authorization).toBe(
    'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,' +
      'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,' +
      'Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
  );
});

test('presigned GET', async () => {
  const url = await presign(creds, { method: 'GET', host: 'examplebucket.s3.amazonaws.com', path: '/test.txt' }, 86400, when);
  expect(url).toContain('X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404');
});

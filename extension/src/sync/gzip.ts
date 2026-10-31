const pipe = async (bytes: Uint8Array, stream: CompressionStream | DecompressionStream) =>
  new Uint8Array(await new Response(new Blob([bytes as BlobPart]).stream().pipeThrough(stream)).arrayBuffer());

export const gzip = (bytes: Uint8Array) => pipe(bytes, new CompressionStream('gzip'));
export const gunzip = (bytes: Uint8Array) => pipe(bytes, new DecompressionStream('gzip'));

export const gzipLines = (lines: Iterable<string>) =>
  gzip(new TextEncoder().encode([...lines].join('\n')));

export const gunzipLines = async (bytes: Uint8Array) =>
  new TextDecoder()
    .decode(await gunzip(bytes))
    .split('\n')
    .filter((l) => l.length > 0);

/// How long a small bucket request (HEAD, listing page, ranged read,
/// DELETE) may take. A stalled connection otherwise waits forever, and
/// every check queued behind it with it.
const bucketRequestTimeout = Duration(seconds: 20);

/// Every small request to a bucket goes through here, so none can forget
/// its timeout. A timeout throws, which callers read as "unknown". Photo
/// bodies never do: they stay on `background_downloader`.
Future<T> bucketRequest<T>(
  Future<T> request, {
  Duration timeout = bucketRequestTimeout,
}) => request.timeout(timeout);

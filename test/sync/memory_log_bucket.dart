import 'package:photos_vault/sync/log_bucket.dart';

/// A bucket in memory with S3's write-once answer and server LastModified.
class MemoryLogBucket implements LogBucket {
  final objects = <String, (List<int>, int)>{};
  int clock = 1793414025000;
  bool dropAnswerAfterNextPut = false;

  @override
  int now() => clock += 10;

  @override
  Future<List<String>> folders(String prefix) async => {
    for (final k in objects.keys)
      if (k.startsWith(prefix) && k.indexOf('/', prefix.length) > 0)
        k.substring(0, k.indexOf('/', prefix.length) + 1),
  }.toList()..sort();

  @override
  Future<List<LogObject>> list(String prefix, {String? startAfter}) async => [
    for (final k in objects.keys.toList()..sort())
      if (k.startsWith(prefix) &&
          (startAfter == null || k.compareTo(startAfter) > 0))
        LogObject(k, objects[k]!.$2),
  ];

  @override
  Future<List<int>> get(String key) async =>
      objects[key]?.$1 ?? (throw LogBucketError(404, 'NoSuchKey'));

  @override
  Future<void> put(
    String key,
    List<int> body, {
    String contentType = '',
  }) async {
    objects[key] = (body, now());
  }

  @override
  Future<PutOnce> putOnce(String key, List<int> body) async {
    final there = objects[key];
    if (there != null) {
      final same =
          there.$1.length == body.length &&
          Iterable<int>.generate(body.length)
              .every((i) => there.$1[i] == body[i]);
      return same ? PutOnce.existsSame : PutOnce.collision;
    }
    objects[key] = (body, now());
    if (dropAnswerAfterNextPut) {
      dropAnswerAfterNextPut = false;
      throw LogBucketError(0, 'connection reset after the PUT landed');
    }
    return PutOnce.written;
  }
}

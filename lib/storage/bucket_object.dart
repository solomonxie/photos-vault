/// One object seen in a bucket listing. No hidden flag, deliberately: this
/// table rides to the bucket in the snapshot, and holds only what any
/// listing of that bucket already shows.
class BucketObject {
  const BucketObject({
    required this.targetId,
    required this.key,
    required this.size,
    required this.lastModified,
  });

  final String targetId;
  final String key;
  final int size;
  final DateTime lastModified;

  String get fileName => key.split('/').last;
  String get directory => key.contains('/')
      ? key.substring(0, key.lastIndexOf('/')).split('/').last
      : '';
}

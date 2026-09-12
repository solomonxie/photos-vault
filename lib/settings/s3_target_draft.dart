/// What was typed on an attempt to add an S3 target that wasn't (yet)
/// saved — kept so a failed or abandoned attempt doesn't mean retyping
/// everything from scratch next time.
class S3TargetDraft {
  const S3TargetDraft({
    required this.id,
    this.accessKeyId = '',
    this.secretAccessKey = '',
    this.bucket = '',
    this.prefix = '',
  });

  final String id;
  final String accessKeyId;
  final String secretAccessKey;
  final String bucket;
  final String prefix;

  Map<String, dynamic> toJson() => {
    'id': id,
    'accessKeyId': accessKeyId,
    'secretAccessKey': secretAccessKey,
    'bucket': bucket,
    'prefix': prefix,
  };

  factory S3TargetDraft.fromJson(Map<String, dynamic> json) => S3TargetDraft(
    id: json['id'] as String,
    accessKeyId: json['accessKeyId'] as String? ?? '',
    secretAccessKey: json['secretAccessKey'] as String? ?? '',
    bucket: json['bucket'] as String? ?? '',
    prefix: json['prefix'] as String? ?? '',
  );
}

/// One configured S3 destination the user backs photos up to. The app
/// supports multiple — each with its own credentials/bucket/prefix.
///
/// S3-only by design: this app exists so photos live in storage the user
/// owns, not another vendor's app-managed cloud (iCloud, Google Photos,
/// etc.) — those already have official apps that do that job.
///
/// Storage tiering (Standard/IA/Glacier/…) is entirely the bucket owner's
/// concern, set up as Lifecycle Rules in their own AWS account. This app's
/// only job is to keep derivatives (thumbnails/medium/originals) under
/// clearly separate key prefixes so those rules can target each one.
class S3BackupTarget {
  const S3BackupTarget({
    required this.id,
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.region,
    required this.bucket,
    this.prefix = '',
  });

  final String id;
  final String accessKeyId;
  final String secretAccessKey;
  final String region;
  final String bucket;
  final String prefix;

  Map<String, dynamic> toJson() => {
    'id': id,
    'accessKeyId': accessKeyId,
    'secretAccessKey': secretAccessKey,
    'region': region,
    'bucket': bucket,
    'prefix': prefix,
  };

  factory S3BackupTarget.fromJson(Map<String, dynamic> json) => S3BackupTarget(
    id: json['id'] as String,
    accessKeyId: json['accessKeyId'] as String? ?? '',
    secretAccessKey: json['secretAccessKey'] as String? ?? '',
    region: json['region'] as String? ?? '',
    bucket: json['bucket'] as String? ?? '',
    prefix: json['prefix'] as String? ?? '',
  );
}

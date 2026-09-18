import 'backup_storage_type.dart';

/// One configured bucket the user backs photos up to. The app supports
/// multiple — each with its own provider/credentials/bucket/prefix.
///
/// Reached over the S3 API by design, whoever runs the bucket: AWS S3,
/// Tencent COS and Alibaba Cloud OSS all answer it, so one signer and one
/// uploader cover all three. What it is *not* is another vendor's
/// app-managed cloud (iCloud, Google Photos, …) — this app exists so photos
/// live in storage the user owns, and those already have official apps.
///
/// Storage tiering (Standard/IA/Glacier/…) is entirely the bucket owner's
/// concern, set up as Lifecycle Rules in their own AWS account. This app's
/// only job is to keep derivatives (thumbnails/medium/originals) under
/// clearly separate key prefixes so those rules can target each one.
/// A key prefix names a *folder* in the bucket, so it always ends in `/`
/// and never starts with one. Typed without the slash, `photos` would put
/// every object at `photosoriginals/…` — one missing character silently
/// scattering a backup across the bucket root. Added for the user rather
/// than rejected: there's only one thing they can have meant.
String normalizeKeyPrefix(String prefix) {
  var out = prefix.trim();
  while (out.startsWith('/')) {
    out = out.substring(1);
  }
  out = out.trim();
  if (out.isEmpty) return '';
  return out.endsWith('/') ? out : '$out/';
}

class S3BackupTarget {
  const S3BackupTarget({
    required this.id,
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.region,
    required this.bucket,
    this.prefix = '',
    this.provider = BackupStorageType.s3,
  });

  final String id;
  final String accessKeyId;
  final String secretAccessKey;
  final String region;
  final String bucket;
  final String prefix;

  /// Which provider's endpoint [region] and [bucket] name. Defaults to S3
  /// so targets saved before the field existed keep working.
  final BackupStorageType provider;

  Map<String, dynamic> toJson() => {
    'id': id,
    'accessKeyId': accessKeyId,
    'secretAccessKey': secretAccessKey,
    'region': region,
    'bucket': bucket,
    'prefix': prefix,
    'provider': provider.name,
  };

  factory S3BackupTarget.fromJson(Map<String, dynamic> json) => S3BackupTarget(
    id: json['id'] as String,
    accessKeyId: json['accessKeyId'] as String? ?? '',
    secretAccessKey: json['secretAccessKey'] as String? ?? '',
    region: json['region'] as String? ?? '',
    bucket: json['bucket'] as String? ?? '',
    prefix: json['prefix'] as String? ?? '',
    provider: backupStorageTypeFromName(json['provider'] as String?),
  );
}

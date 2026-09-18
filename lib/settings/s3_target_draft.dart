import 'backup_storage_type.dart';

/// What was typed on an attempt to add a backup target that wasn't (yet)
/// saved — kept so a failed or abandoned attempt doesn't mean retyping
/// everything from scratch next time.
class S3TargetDraft {
  const S3TargetDraft({
    required this.id,
    this.accessKeyId = '',
    this.secretAccessKey = '',
    this.bucket = '',
    this.prefix = '',
    this.region = '',
    this.provider = BackupStorageType.s3,
  });

  final String id;
  final String accessKeyId;
  final String secretAccessKey;
  final String bucket;
  final String prefix;

  /// Empty for S3, whose region is detected rather than typed.
  final String region;

  final BackupStorageType provider;

  Map<String, dynamic> toJson() => {
    'id': id,
    'accessKeyId': accessKeyId,
    'secretAccessKey': secretAccessKey,
    'bucket': bucket,
    'prefix': prefix,
    'region': region,
    'provider': provider.name,
  };

  factory S3TargetDraft.fromJson(Map<String, dynamic> json) => S3TargetDraft(
    id: json['id'] as String,
    accessKeyId: json['accessKeyId'] as String? ?? '',
    secretAccessKey: json['secretAccessKey'] as String? ?? '',
    bucket: json['bucket'] as String? ?? '',
    prefix: json['prefix'] as String? ?? '',
    region: json['region'] as String? ?? '',
    provider: backupStorageTypeFromName(json['provider'] as String?),
  );
}

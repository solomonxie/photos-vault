part of 'backup_target.dart';

/// One configured S3 destination the user backs photos up to. The app
/// supports multiple — each with its own credentials/bucket/prefix.
///
/// Storage tiering (Standard/IA/Glacier/…) is entirely the bucket owner's
/// concern, set up as Lifecycle Rules in their own AWS account. This app's
/// only job is to keep derivatives (thumbnails/medium/originals) under
/// clearly separate key prefixes so those rules can target each one.
class S3BackupTarget extends BackupTarget {
  const S3BackupTarget({
    required super.id,
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.region,
    required this.bucket,
    this.prefix = '',
  });

  static const jsonType = 's3';

  final String accessKeyId;
  final String secretAccessKey;
  final String region;
  final String bucket;
  final String prefix;

  @override
  Map<String, dynamic> toJson() => {
    'type': jsonType,
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

/// S3 storage classes selectable per derivative tier (thumbnail/medium/original).
/// `null` means "leave it to the bucket default" — the user's own Lifecycle
/// Rules do the tiering; this is just an optional day-1 override so originals
/// don't sit at Standard rates until the first lifecycle evaluation.
enum S3StorageClass {
  standard('STANDARD'),
  standardIa('STANDARD_IA'),
  oneZoneIa('ONEZONE_IA'),
  intelligentTiering('INTELLIGENT_TIERING'),
  glacierInstantRetrieval('GLACIER_IR'),
  glacier('GLACIER'),
  deepArchive('DEEP_ARCHIVE');

  const S3StorageClass(this.awsValue);

  /// The literal value S3 expects in the `x-amz-storage-class` header.
  final String awsValue;

  static S3StorageClass? fromAwsValue(String? value) {
    for (final storageClass in values) {
      if (storageClass.awsValue == value) return storageClass;
    }
    return null;
  }
}

class AwsSettings {
  const AwsSettings({
    this.accessKeyId = '',
    this.secretAccessKey = '',
    this.region = '',
    this.bucket = '',
    this.prefix = '',
    this.thumbnailStorageClass,
    this.mediumStorageClass,
    this.originalStorageClass,
  });

  final String accessKeyId;
  final String secretAccessKey;
  final String region;
  final String bucket;
  final String prefix;
  final S3StorageClass? thumbnailStorageClass;
  final S3StorageClass? mediumStorageClass;
  final S3StorageClass? originalStorageClass;

  bool get hasCredentials =>
      accessKeyId.isNotEmpty && secretAccessKey.isNotEmpty && region.isNotEmpty && bucket.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'accessKeyId': accessKeyId,
    'secretAccessKey': secretAccessKey,
    'region': region,
    'bucket': bucket,
    'prefix': prefix,
    'thumbnailStorageClass': thumbnailStorageClass?.awsValue,
    'mediumStorageClass': mediumStorageClass?.awsValue,
    'originalStorageClass': originalStorageClass?.awsValue,
  };

  factory AwsSettings.fromJson(Map<String, dynamic> json) {
    return AwsSettings(
      accessKeyId: json['accessKeyId'] as String? ?? '',
      secretAccessKey: json['secretAccessKey'] as String? ?? '',
      region: json['region'] as String? ?? '',
      bucket: json['bucket'] as String? ?? '',
      prefix: json['prefix'] as String? ?? '',
      thumbnailStorageClass: S3StorageClass.fromAwsValue(json['thumbnailStorageClass'] as String?),
      mediumStorageClass: S3StorageClass.fromAwsValue(json['mediumStorageClass'] as String?),
      originalStorageClass: S3StorageClass.fromAwsValue(json['originalStorageClass'] as String?),
    );
  }
}

/// Object storage backend a [S3BackupTarget]-like entry lives on.
///
/// The three available ones all speak the S3 API — Tencent COS and Alibaba
/// Cloud OSS through their own S3-compatible endpoints — so they share one
/// signer, one uploader and one browser, and differ only in hostname,
/// where the region comes from, and what each console calls the two halves
/// of a credential. The rest are listed so the picker in Add Backup shows
/// the roadmap, disabled until each one ships its own uploader.
enum BackupStorageType {
  s3,
  tencentCos,
  aliyunOss,
  googleCloudStorage,
  azureBlob,
  backblazeB2,
}

class BackupStorageTypeMeta {
  const BackupStorageTypeMeta({
    required this.type,
    required this.name,
    required this.shortName,
    required this.available,
    this.regions = const [],
  });

  final BackupStorageType type;
  final String name;

  /// What fits on a target row next to the region.
  final String shortName;

  final bool available;

  /// The regions to pick from. Empty means the provider tells us the region
  /// itself (AWS, from the bucket name) so the user never picks one.
  final List<String> regions;

  bool get detectsRegion => regions.isEmpty;
}

/// COS's public regions, as the console spells them. Financial-cloud and
/// dedicated-zone regions are left out — they need a different endpoint
/// domain altogether, not just another id here.
const _tencentCosRegions = [
  'ap-beijing',
  'ap-nanjing',
  'ap-shanghai',
  'ap-guangzhou',
  'ap-chengdu',
  'ap-chongqing',
  'ap-hongkong',
  'ap-singapore',
  'ap-jakarta',
  'ap-seoul',
  'ap-tokyo',
  'ap-bangkok',
  'ap-mumbai',
  'na-siliconvalley',
  'na-ashburn',
  'na-toronto',
  'sa-saopaulo',
  'eu-frankfurt',
];

/// OSS regions without the `oss-` prefix the endpoint adds back — the id
/// Alibaba's console shows for a bucket is `cn-hangzhou`, not
/// `oss-cn-hangzhou`.
const _aliyunOssRegions = [
  'cn-hangzhou',
  'cn-shanghai',
  'cn-nanjing',
  'cn-fuzhou',
  'cn-qingdao',
  'cn-beijing',
  'cn-zhangjiakou',
  'cn-huhehaote',
  'cn-wulanchabu',
  'cn-shenzhen',
  'cn-heyuan',
  'cn-guangzhou',
  'cn-chengdu',
  'cn-hongkong',
  'us-west-1',
  'us-east-1',
  'ap-northeast-1',
  'ap-northeast-2',
  'ap-southeast-1',
  'ap-southeast-2',
  'ap-southeast-3',
  'ap-southeast-5',
  'ap-southeast-6',
  'ap-southeast-7',
  'ap-south-1',
  'eu-central-1',
  'eu-west-1',
  'me-east-1',
];

const backupStorageTypes = <BackupStorageTypeMeta>[
  BackupStorageTypeMeta(
    type: BackupStorageType.s3,
    name: 'Amazon S3',
    shortName: 'S3',
    available: true,
  ),
  BackupStorageTypeMeta(
    type: BackupStorageType.tencentCos,
    name: 'Tencent Cloud COS',
    shortName: 'COS',
    available: true,
    regions: _tencentCosRegions,
  ),
  BackupStorageTypeMeta(
    type: BackupStorageType.aliyunOss,
    name: 'Alibaba Cloud OSS',
    shortName: 'OSS',
    available: true,
    regions: _aliyunOssRegions,
  ),
  BackupStorageTypeMeta(
    type: BackupStorageType.googleCloudStorage,
    name: 'Google Cloud Storage',
    shortName: 'GCS',
    available: false,
  ),
  BackupStorageTypeMeta(
    type: BackupStorageType.azureBlob,
    name: 'Azure Blob Storage',
    shortName: 'Azure',
    available: false,
  ),
  BackupStorageTypeMeta(
    type: BackupStorageType.backblazeB2,
    name: 'Backblaze B2',
    shortName: 'B2',
    available: false,
  ),
];

BackupStorageTypeMeta backupStorageTypeMeta(BackupStorageType type) =>
    backupStorageTypes.firstWhere((m) => m.type == type);

/// Reads a persisted [BackupStorageType.name] back. Anything unrecognised
/// — an older build's entry, which predates the field entirely — is S3,
/// the only backend those builds could write.
BackupStorageType backupStorageTypeFromName(String? name) => BackupStorageType
    .values
    .firstWhere((t) => t.name == name, orElse: () => BackupStorageType.s3);

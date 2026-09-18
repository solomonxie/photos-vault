import 'backup_storage_type.dart';
import 's3_backup_target.dart';

/// Where a bucket's S3 API answers. One host per provider is the whole
/// difference between them: COS and OSS implement the same requests, the
/// same SigV4 signing (service `s3`) and the same XML, so every signed call
/// in the app routes through here instead of hard-coding AWS's hostname.
///
/// Both non-AWS hosts are the vendors' own documented S3-compatible
/// endpoints, virtual-hosted style (bucket in the hostname), which is what
/// they tell AWS SDK users to configure. For COS the bucket name is the one
/// with the APPID suffix — `my-photos-1250000000` — exactly as its console
/// shows it.
String bucketHost({
  required BackupStorageType provider,
  required String region,
  required String bucket,
}) => switch (provider) {
  BackupStorageType.s3 => '$bucket.s3.$region.amazonaws.com',
  BackupStorageType.tencentCos => '$bucket.cos.$region.myqcloud.com',
  // OSS answers the S3 API on a separate `s3.`-prefixed host; plain
  // `oss-<region>.aliyuncs.com` is its own native protocol, which shares
  // the verbs but not the signature.
  BackupStorageType.aliyunOss => '$bucket.s3.oss-$region.aliyuncs.com',
  _ => throw UnsupportedError('${provider.name} has no S3 endpoint'),
};

/// The region a request's SigV4 credential scope names. The same id the
/// host uses, for all three: COS verifies against the region in the scope,
/// and OSS ignores it entirely (its own examples pass everything from
/// `cn-hangzhou` to `AWS_GLOBAL`), so the bucket's own region is both
/// correct and the one worth showing the user.
String signingRegion(S3BackupTarget target) => target.region;

Uri bucketUri({
  required BackupStorageType provider,
  required String region,
  required String bucket,
  String path = '/',
  Map<String, dynamic>? query,
}) => Uri.https(
  bucketHost(provider: provider, region: region, bucket: bucket),
  path,
  query,
);

Uri targetUri(
  S3BackupTarget target, {
  String path = '/',
  Map<String, dynamic>? query,
}) => bucketUri(
  provider: target.provider,
  region: target.region,
  bucket: target.bucket,
  path: path,
  query: query,
);

/// The `scheme://bucket/prefix` shorthand each provider's own tooling uses
/// — what a target row shows, and what the paste box accepts back.
String bucketUriScheme(BackupStorageType provider) => switch (provider) {
  BackupStorageType.tencentCos => 'cos',
  BackupStorageType.aliyunOss => 'oss',
  _ => 's3',
};

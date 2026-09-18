import 'package:bring_your_own_photos/settings/backup_storage_type.dart';
import 'package:bring_your_own_photos/settings/bucket_endpoint.dart';
import 'package:bring_your_own_photos/settings/s3_backup_target.dart';
import 'package:flutter_test/flutter_test.dart';

S3BackupTarget _target(BackupStorageType provider, String region) =>
    S3BackupTarget(
      id: 'id',
      accessKeyId: 'a',
      secretAccessKey: 'b',
      region: region,
      bucket: 'my-photos',
      prefix: 'backup/',
      provider: provider,
    );

void main() {
  test('each provider gets its own virtual-hosted host', () {
    expect(
      bucketHost(
        provider: BackupStorageType.s3,
        region: 'eu-west-1',
        bucket: 'my-photos',
      ),
      'my-photos.s3.eu-west-1.amazonaws.com',
    );
    expect(
      bucketHost(
        provider: BackupStorageType.tencentCos,
        region: 'ap-guangzhou',
        bucket: 'my-photos-1250000000',
      ),
      'my-photos-1250000000.cos.ap-guangzhou.myqcloud.com',
    );
    // The `s3.` label is what separates OSS's S3 API from its native one.
    expect(
      bucketHost(
        provider: BackupStorageType.aliyunOss,
        region: 'cn-hangzhou',
        bucket: 'my-photos',
      ),
      'my-photos.s3.oss-cn-hangzhou.aliyuncs.com',
    );
  });

  test('a backend with no uploader yet has no endpoint to offer', () {
    expect(
      () => bucketHost(
        provider: BackupStorageType.azureBlob,
        region: 'r',
        bucket: 'b',
      ),
      throwsUnsupportedError,
    );
  });

  test('targetUri carries the key and query onto the right host', () {
    final uri = targetUri(
      _target(BackupStorageType.tencentCos, 'ap-shanghai'),
      path: '/backup/originals/IMG_0001.JPG',
      query: {'list-type': '2'},
    );

    expect(uri.host, 'my-photos.cos.ap-shanghai.myqcloud.com');
    expect(uri.path, '/backup/originals/IMG_0001.JPG');
    expect(uri.queryParameters['list-type'], '2');
    expect(uri.scheme, 'https');
  });

  test('the signature is scoped to the bucket\'s own region', () {
    expect(
      signingRegion(_target(BackupStorageType.aliyunOss, 'cn-hangzhou')),
      'cn-hangzhou',
    );
  });

  test('each provider shows the shorthand its own tooling uses', () {
    expect(bucketUriScheme(BackupStorageType.s3), 's3');
    expect(bucketUriScheme(BackupStorageType.tencentCos), 'cos');
    expect(bucketUriScheme(BackupStorageType.aliyunOss), 'oss');
  });
}

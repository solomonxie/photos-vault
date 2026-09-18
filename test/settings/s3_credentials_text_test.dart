import 'package:photos_vault/settings/backup_storage_type.dart';
import 'package:photos_vault/settings/s3_credentials_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the documented block', () {
    final parsed = S3CredentialsText.parse('''
bucket: my-photos
prefix: photos-vault/
access_key_id: AKIAIOSFODNN7EXAMPLE
secret_access_key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
''');

    expect(parsed.bucket, 'my-photos');
    expect(parsed.prefix, 'photos-vault/');
    expect(parsed.accessKeyId, 'AKIAIOSFODNN7EXAMPLE');
    expect(parsed.secretAccessKey, 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY');
    expect(parsed.fieldCount, 4);
  });

  test('reads shell exports and AWS_-prefixed names', () {
    final parsed = S3CredentialsText.parse('''
# my bucket
export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=secret-value
BUCKET=holiday-snaps
''');

    expect(parsed.accessKeyId, 'AKIAIOSFODNN7EXAMPLE');
    expect(parsed.secretAccessKey, 'secret-value');
    expect(parsed.bucket, 'holiday-snaps');
    expect(parsed.prefix, isNull);
  });

  test('reads a JSON-ish block, quotes and commas and all', () {
    final parsed = S3CredentialsText.parse('''
{
  "bucket": "my-photos",
  "accessKeyId": "AKIA123",
  "secretAccessKey": "shh",
}
''');

    expect(parsed.bucket, 'my-photos');
    expect(parsed.accessKeyId, 'AKIA123');
    expect(parsed.secretAccessKey, 'shh');
  });

  test('an s3:// URI carries both bucket and prefix', () {
    final parsed = S3CredentialsText.parse('s3://my-photos/raw/2020/');

    expect(parsed.bucket, 'my-photos');
    expect(parsed.prefix, 'raw/2020/');
  });

  test('a bare bucket URI leaves the prefix alone', () {
    final parsed = S3CredentialsText.parse('s3://my-photos');

    expect(parsed.bucket, 'my-photos');
    expect(parsed.prefix, isNull);
  });

  test('tolerates spaced keys, mixed case and blank lines', () {
    final parsed = S3CredentialsText.parse('''

  Bucket : my-photos

  Access Key ID : AKIA123
''');

    expect(parsed.bucket, 'my-photos');
    expect(parsed.accessKeyId, 'AKIA123');
  });

  test('keeps a secret key containing separators intact', () {
    final parsed = S3CredentialsText.parse('secret_access_key: a:b=c/d+e');

    expect(parsed.secretAccessKey, 'a:b=c/d+e');
  });

  test('the first value wins when a name repeats', () {
    final parsed = S3CredentialsText.parse('bucket: first\nbucket: second');

    expect(parsed.bucket, 'first');
  });

  test('unrelated text parses to nothing', () {
    final parsed = S3CredentialsText.parse('hello there\nnothing to see');

    expect(parsed.isEmpty, isTrue);
    expect(parsed.fieldCount, 0);
  });

  test('a COS console URL names the provider, region and bucket at once', () {
    final parsed = S3CredentialsText.parse('''
https://my-photos-1250000000.cos.ap-guangzhou.myqcloud.com
SecretId: AKIDzExAmPlE
SecretKey: shh
''');

    expect(parsed.provider, BackupStorageType.tencentCos);
    expect(parsed.region, 'ap-guangzhou');
    expect(parsed.bucket, 'my-photos-1250000000');
    expect(parsed.accessKeyId, 'AKIDzExAmPlE');
    expect(parsed.secretAccessKey, 'shh');
  });

  test('an OSS endpoint without a bucket still sets provider and region', () {
    final parsed = S3CredentialsText.parse('''
endpoint = https://s3.oss-cn-hangzhou.aliyuncs.com
bucket: my-photos
AccessKeyId=LTAI5tExAmPlE
AccessKeySecret=shh
''');

    expect(parsed.provider, BackupStorageType.aliyunOss);
    expect(parsed.region, 'cn-hangzhou');
    // `s3` is a hostname label there, not the bucket.
    expect(parsed.bucket, 'my-photos');
    expect(parsed.accessKeyId, 'LTAI5tExAmPlE');
    expect(parsed.secretAccessKey, 'shh');
  });

  test('oss:// and cos:// carry bucket and prefix like s3:// does', () {
    final oss = S3CredentialsText.parse('oss://my-photos/raw/');
    expect(oss.provider, BackupStorageType.aliyunOss);
    expect(oss.bucket, 'my-photos');
    expect(oss.prefix, 'raw/');

    final cos = S3CredentialsText.parse('cos://my-photos-125/raw/');
    expect(cos.provider, BackupStorageType.tencentCos);
    expect(cos.bucket, 'my-photos-125');
  });

  test('a COS bucket pasted without its APPID gets one appended', () {
    final parsed = S3CredentialsText.parse('''
bucket: my-photos
appid: 1250000000
region: ap-chengdu
''');

    expect(parsed.bucket, 'my-photos-1250000000');
    expect(parsed.region, 'ap-chengdu');
  });

  test('an OSS region written with its endpoint prefix is stored short', () {
    expect(
      S3CredentialsText.parse('region: oss-cn-shanghai').region,
      'cn-shanghai',
    );
  });

  test('a plain S3 block still parses as S3, region left to detection', () {
    final parsed = S3CredentialsText.parse('s3://my-photos/raw/');
    expect(parsed.provider, BackupStorageType.s3);
    expect(parsed.region, isNull);
  });
}

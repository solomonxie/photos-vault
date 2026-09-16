import 'package:bring_your_own_photos/settings/s3_credentials_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the documented block', () {
    final parsed = S3CredentialsText.parse('''
bucket: my-photos
prefix: bring-your-own-photos/
access_key_id: AKIAIOSFODNN7EXAMPLE
secret_access_key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
''');

    expect(parsed.bucket, 'my-photos');
    expect(parsed.prefix, 'bring-your-own-photos/');
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
}

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/settings/s3_xml.dart' as sx;

/// A real `ListObjectsV2` shape: default namespace on the root, one folder
/// under `CommonPrefixes`, two objects, truncated with a token.
const _listing = '''
<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>bucket</Name>
  <Prefix>photos-vault/</Prefix>
  <IsTruncated>true</IsTruncated>
  <NextContinuationToken>1ueGcxLPRx1Tr/XYExFnhUT4</NextContinuationToken>
  <CommonPrefixes>
    <Prefix>photos-vault/originals/</Prefix>
  </CommonPrefixes>
  <Contents>
    <Key>photos-vault/originals/manual_a.jpg</Key>
    <LastModified>2026-09-18T11:22:33.000Z</LastModified>
    <Size>204800</Size>
  </Contents>
  <Contents>
    <Key>photos-vault/originals/Tom &amp; Jerry.jpg</Key>
    <LastModified>2026-09-19T00:00:00.000Z</LastModified>
    <Size>17</Size>
  </Contents>
</ListBucketResult>
''';

void main() {
  test('reads every block of a repeated element, in document order', () {
    final blocks = sx.blocksOf(_listing, 'Contents');

    expect(blocks, hasLength(2));
    expect(sx.textOf(blocks.first, 'Size'), '204800');
    expect(sx.textOf(blocks.last, 'Size'), '17');
  });

  test('reads a child out of its own block, not the whole document', () {
    // Both the root and CommonPrefixes carry a <Prefix>. Scoping to the
    // block is what keeps the folder list from picking up the request's
    // own prefix as a folder.
    final folder = sx.blocksOf(_listing, 'CommonPrefixes').single;

    expect(sx.textOf(folder, 'Prefix'), 'photos-vault/originals/');
    expect(sx.textOf(_listing, 'Prefix'), 'photos-vault/');
  });

  test('unescapes entities in values', () {
    final keys = sx
        .blocksOf(_listing, 'Contents')
        .map((b) => sx.textOf(b, 'Key'))
        .toList();

    expect(keys.last, 'photos-vault/originals/Tom & Jerry.jpg');
  });

  test('undoes &amp; last, so an escaped entity survives', () {
    expect(
      sx.textOf('<K>&amp;lt;not a tag&amp;gt;</K>', 'K'),
      '&lt;not a tag&gt;',
    );
  });

  test('decodes numeric character references, decimal and hex', () {
    expect(sx.textOf('<K>caf&#233; &#x1F600;</K>', 'K'), 'café 😀');
  });

  test('reads the truncation flag and its token', () {
    expect(sx.textOf(_listing, 'IsTruncated'), 'true');
    expect(
      sx.textOf(_listing, 'NextContinuationToken'),
      '1ueGcxLPRx1Tr/XYExFnhUT4',
    );
  });

  test('pulls the Code out of an S3 error document', () {
    const error = '''
<?xml version="1.0" encoding="UTF-8"?>
<Error><Code>SignatureDoesNotMatch</Code><Message>nope</Message></Error>
''';

    expect(sx.textOf(error, 'Code'), 'SignatureDoesNotMatch');
  });

  test('a missing element is null, an empty one is an empty string', () {
    expect(sx.textOf(_listing, 'Nonsense'), isNull);
    expect(sx.textOf('<Key></Key>', 'Key'), '');
    // Self-closing is present-but-empty, not absent.
    expect(sx.textOf('<Key/>', 'Key'), '');
    expect(sx.textOf('<Key />', 'Key'), '');
  });

  test('an element carrying attributes is still read', () {
    expect(sx.textOf('<Key xml:lang="en">a.jpg</Key>', 'Key'), 'a.jpg');
  });

  test('a truncated or non-XML body yields nothing rather than throwing', () {
    // A proxy's HTML error page, or a response cut off mid-flight — the
    // callers all read "nothing" as "couldn't parse it".
    expect(
      sx.textOf('<html><body>502 Bad Gateway</body></html>', 'Code'),
      isNull,
    );
    expect(sx.blocksOf('<Contents><Key>a.jpg', 'Contents'), isEmpty);
    expect(sx.textsOf('', 'Key'), isEmpty);
  });

  test('textsOf returns every match, blocksOf keeps the raw markup', () {
    expect(sx.textsOf(_listing, 'Size'), ['204800', '17']);
    expect(
      sx.blocksOf(_listing, 'CommonPrefixes').single,
      contains('<Prefix>'),
    );
  });
}

/// A pasted block of S3 connection details, pulled apart into the fields
/// the Add form asks for.
///
/// Credentials arrive as text — out of a console, a password manager, a
/// chat message, a `.env` file — and retyping four values by hand is how a
/// one-character error gets into a secret key. Anything shaped like
/// `key: value` or `key=value` counts, one per line, so all of these land
/// in the same place:
///
/// ```text
///   bucket: my-photos          BUCKET=my-photos       s3://my-photos/raw/
///   prefix: raw/               AWS_ACCESS_KEY_ID=…    aws_access_key_id = …
///   access_key_id: AKIA…       "bucket": "my-photos",
/// ```
class S3CredentialsText {
  const S3CredentialsText({
    this.bucket,
    this.prefix,
    this.accessKeyId,
    this.secretAccessKey,
  });

  final String? bucket;
  final String? prefix;
  final String? accessKeyId;
  final String? secretAccessKey;

  /// How many fields were recognised — zero means the text wasn't a
  /// credentials block at all.
  int get fieldCount => [
    bucket,
    prefix,
    accessKeyId,
    secretAccessKey,
  ].where((v) => v != null).length;

  bool get isEmpty => fieldCount == 0;

  static const _aliases = <String, String>{
    'bucket': 'bucket',
    'bucketname': 'bucket',
    's3bucket': 'bucket',
    'prefix': 'prefix',
    'keyprefix': 'prefix',
    'folder': 'prefix',
    'path': 'prefix',
    'accesskeyid': 'accessKeyId',
    'awsaccesskeyid': 'accessKeyId',
    'accesskey': 'accessKeyId',
    'keyid': 'accessKeyId',
    'secretaccesskey': 'secretAccessKey',
    'awssecretaccesskey': 'secretAccessKey',
    'secretkey': 'secretAccessKey',
    'secret': 'secretAccessKey',
  };

  /// Everything but letters and digits goes, so `AWS_ACCESS_KEY_ID`,
  /// `Access Key ID` and `"accessKeyId"` are all the same key. A leading
  /// `export ` goes first, or a copied shell line would name no field.
  static String _normalizeKey(String key) => key
      .trim()
      .replaceFirst(RegExp(r'^export\s+', caseSensitive: false), '')
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]'), '');

  /// Strips the punctuation a value picks up from JSON, YAML or a shell
  /// export — quotes, a trailing comma or semicolon, an inline comment.
  static String _cleanValue(String value) {
    var out = value.trim();
    out = out.replaceFirst(RegExp(r'[,;]+$'), '').trim();
    if (out.length >= 2 &&
        ((out.startsWith('"') && out.endsWith('"')) ||
            (out.startsWith("'") && out.endsWith("'")))) {
      out = out.substring(1, out.length - 1);
    }
    return out.trim();
  }

  static S3CredentialsText parse(String text) {
    String? bucket;
    String? prefix;
    String? accessKeyId;
    String? secretAccessKey;

    for (final rawLine in text.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }

      // `s3://bucket/some/prefix/` carries two fields in one token.
      final uri = RegExp(r's3://([^/\s"]+)/?(\S*)').firstMatch(line);
      if (uri != null) {
        bucket ??= uri.group(1);
        final uriPrefix = _cleanValue(uri.group(2) ?? '');
        if (uriPrefix.isNotEmpty) prefix ??= uriPrefix;
        continue;
      }

      final separator = RegExp('[:=]').firstMatch(line);
      if (separator == null) continue;
      final field = _aliases[_normalizeKey(line.substring(0, separator.start))];
      if (field == null) continue;
      final value = _cleanValue(line.substring(separator.end));
      if (value.isEmpty) continue;

      switch (field) {
        case 'bucket':
          bucket ??= value;
        case 'prefix':
          prefix ??= value;
        case 'accessKeyId':
          accessKeyId ??= value;
        case 'secretAccessKey':
          secretAccessKey ??= value;
      }
    }

    return S3CredentialsText(
      bucket: bucket,
      prefix: prefix,
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
    );
  }
}

import 'backup_storage_type.dart';

/// A pasted block of bucket connection details, pulled apart into the
/// fields the Add form asks for.
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
///   SecretId: AKID…            AccessKeySecret=…      oss://my-photos/raw/
/// ```
///
/// A pasted endpoint or console URL is worth more than any of them: it
/// names the provider, the region and usually the bucket at once, which is
/// the whole of what COS and OSS can't work out for themselves.
///
/// ```text
///   https://my-photos-1250000000.cos.ap-guangzhou.myqcloud.com
///   endpoint: https://s3.oss-cn-hangzhou.aliyuncs.com
/// ```
class S3CredentialsText {
  const S3CredentialsText({
    this.bucket,
    this.prefix,
    this.accessKeyId,
    this.secretAccessKey,
    this.region,
    this.provider,
  });

  final String? bucket;
  final String? prefix;
  final String? accessKeyId;
  final String? secretAccessKey;

  /// Only ever set from something that says so outright — a `region:` line
  /// or an endpoint host. S3's is detected from the bucket instead.
  final String? region;

  final BackupStorageType? provider;

  /// How many fields were recognised — zero means the text wasn't a
  /// credentials block at all.
  int get fieldCount => [
    bucket,
    prefix,
    accessKeyId,
    secretAccessKey,
    region,
    provider,
  ].where((v) => v != null).length;

  bool get isEmpty => fieldCount == 0;

  static const _aliases = <String, String>{
    'bucket': 'bucket',
    'bucketname': 'bucket',
    's3bucket': 'bucket',
    'cosbucket': 'bucket',
    'ossbucket': 'bucket',
    'prefix': 'prefix',
    'keyprefix': 'prefix',
    'folder': 'prefix',
    'path': 'prefix',
    'accesskeyid': 'accessKeyId',
    'awsaccesskeyid': 'accessKeyId',
    'ossaccesskeyid': 'accessKeyId',
    'accesskey': 'accessKeyId',
    'keyid': 'accessKeyId',
    // Tencent's console calls the pair SecretId/SecretKey — an id that
    // reads like a secret, and the one field name most likely to be pasted
    // into the wrong box by hand.
    'secretid': 'accessKeyId',
    'cossecretid': 'accessKeyId',
    'secretaccesskey': 'secretAccessKey',
    'awssecretaccesskey': 'secretAccessKey',
    'accesskeysecret': 'secretAccessKey',
    'ossaccesskeysecret': 'secretAccessKey',
    'secretkey': 'secretAccessKey',
    'cossecretkey': 'secretAccessKey',
    'secret': 'secretAccessKey',
    'region': 'region',
    'awsregion': 'region',
    'cosregion': 'region',
    'ossregion': 'region',
    'location': 'region',
    'endpoint': 'endpoint',
    'url': 'endpoint',
    'host': 'endpoint',
    'domain': 'endpoint',
    // COS buckets are named `<name>-<appid>`; consoles and SDK snippets
    // often hand the two over separately.
    'appid': 'appId',
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

  /// `<bucket>.s3.<region>.amazonaws.com`, `<bucket>.cos.<region>.myqcloud.com`,
  /// `<bucket>.s3.oss-<region>.aliyuncs.com` and each one's bare (bucketless)
  /// endpoint, in the one place that knows all three.
  static final _hostPatterns = <BackupStorageType, RegExp>{
    BackupStorageType.s3: RegExp(
      r'(?:([a-z0-9][a-z0-9.-]*)\.)?s3[.-]([a-z0-9-]+)\.amazonaws\.com',
      caseSensitive: false,
    ),
    BackupStorageType.tencentCos: RegExp(
      r'(?:([a-z0-9][a-z0-9.-]*)\.)?cos\.([a-z0-9-]+)\.myqcloud\.com',
      caseSensitive: false,
    ),
    BackupStorageType.aliyunOss: RegExp(
      r'(?:([a-z0-9][a-z0-9.-]*?)\.)?(?:s3\.)?oss-([a-z0-9-]+)\.aliyuncs\.com',
      caseSensitive: false,
    ),
  };

  static S3CredentialsText parse(String text) {
    String? bucket;
    String? prefix;
    String? accessKeyId;
    String? secretAccessKey;
    String? region;
    String? appId;
    BackupStorageType? provider;

    /// An endpoint names a provider and a region, and carries the bucket
    /// whenever it's the virtual-hosted form the console shows.
    bool readEndpoint(String line) {
      for (final entry in _hostPatterns.entries) {
        final match = entry.value.firstMatch(line);
        if (match == null) continue;
        provider ??= entry.key;
        region ??= match.group(2)!.toLowerCase();
        // `s3.oss-cn-hangzhou…` leaves an `s3` label behind on the
        // bucketless form; it's a hostname part, not a bucket name.
        final host = match.group(1)?.toLowerCase();
        if (host != null && host.isNotEmpty && host != 's3') {
          bucket ??= host;
        }
        return true;
      }
      return false;
    }

    for (final rawLine in text.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }

      // `s3://bucket/some/prefix/` carries two fields in one token — and
      // `cos://` / `oss://`, what each vendor's own CLI writes, a third.
      final uri = RegExp(r'(s3|cos|oss)://([^/\s"]+)/?(\S*)').firstMatch(line);
      if (uri != null) {
        provider ??= switch (uri.group(1)!.toLowerCase()) {
          'cos' => BackupStorageType.tencentCos,
          'oss' => BackupStorageType.aliyunOss,
          _ => BackupStorageType.s3,
        };
        bucket ??= uri.group(2);
        final uriPrefix = _cleanValue(uri.group(3) ?? '');
        if (uriPrefix.isNotEmpty) prefix ??= uriPrefix;
        continue;
      }

      if (readEndpoint(line)) continue;

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
        case 'region':
          // OSS writes its region both ways; the app stores the short one.
          region ??= value.toLowerCase().replaceFirst(RegExp('^oss-'), '');
        case 'appId':
          appId ??= value;
        case 'endpoint':
          readEndpoint(value);
      }
    }

    // A COS bucket is addressed as `<name>-<appid>`, so a name pasted
    // without it would 404 on every request.
    final name = bucket;
    final suffix = appId;
    if (name != null && suffix != null && !name.endsWith('-$suffix')) {
      bucket = '$name-$suffix';
    }

    return S3CredentialsText(
      bucket: bucket,
      prefix: prefix,
      accessKeyId: accessKeyId,
      secretAccessKey: secretAccessKey,
      region: region,
      provider: provider,
    );
  }
}

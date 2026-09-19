/// Just enough XML for the handful of S3 responses this app reads.
///
/// `ListObjectsV2` pages and S3 error documents are flat, attribute-free,
/// default-namespaced element trees — `<Contents><Key>…</Key></Contents>`.
/// Reading them with a general parser cost `xml` + `petitparser`, 155 KB of
/// the Dart snapshot, to answer four questions. See CLAUDE.md's size
/// budget.
///
/// Deliberately *not* a general parser. No namespace prefixes, no
/// attributes worth reading, no CDATA, and no element nested inside another
/// of the same name — none of which S3 emits. Anything it can't read comes
/// back empty rather than guessed at, which is what every caller already
/// treats as "couldn't read it".
library;

const _entities = {'&lt;': '<', '&gt;': '>', '&quot;': '"', '&apos;': "'"};

/// `&amp;` is undone last, so `&amp;lt;` decodes to the literal `&lt;`
/// rather than to `<`.
String _unescape(String value) {
  var out = value;
  for (final entry in _entities.entries) {
    out = out.replaceAll(entry.key, entry.value);
  }
  out = out.replaceAllMapped(
    RegExp(r'&#(x?)([0-9a-fA-F]+);'),
    (m) => String.fromCharCode(
      int.parse(m.group(2)!, radix: m.group(1)!.isEmpty ? 10 : 16),
    ),
  );
  return out.replaceAll('&amp;', '&');
}

RegExp _tag(String name) =>
    RegExp('<$name(?:\\s[^>]*)?>(.*?)</$name>', dotAll: true);

/// The raw inner markup of every `<name>` element, in document order —
/// for reading children out of with [textOf].
List<String> blocksOf(String body, String name) =>
    _tag(name).allMatches(body).map((m) => m.group(1)!).toList();

/// The unescaped text of every `<name>` element, in document order.
List<String> textsOf(String body, String name) =>
    blocksOf(body, name).map(_unescape).toList();

/// The unescaped text of the first `<name>`, or null if there isn't one.
/// A self-closing `<name/>` reads as an empty string, not as absent.
String? textOf(String body, String name) {
  final match = _tag(name).firstMatch(body);
  if (match != null) return _unescape(match.group(1)!);
  return RegExp('<$name(?:\\s[^>]*)?/>').hasMatch(body) ? '' : null;
}

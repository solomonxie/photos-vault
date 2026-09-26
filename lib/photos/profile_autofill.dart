import 'dart:convert';

/// Where a suggestion would go if it were accepted.
///
/// A closed set, and deliberately: a vendor is being asked to fill in a form,
/// and one that could propose anywhere would be one whose replies had to be
/// understood before they could be shown. Anything outside this is dropped.
enum SuggestionTarget {
  bio,
  trait,
  customField,
  group,
  education,
  job,
  place,
  tag,
}

/// One thing the AI thinks belongs on a profile, and nothing is written until
/// somebody says so.
class ProfileSuggestion {
  const ProfileSuggestion({
    required this.target,
    required this.label,
    this.value = '',
    this.detail = '',
  });

  final SuggestionTarget target;

  /// What it is called — a trait key, a field name, a school, an employer, a
  /// group, or the tag itself.
  final String label;

  /// What it says. Empty where [label] is the whole of it, as for a tag.
  final String value;

  /// Anything extra worth showing before accepting, most often a date range.
  /// Never written anywhere: it is there so a reader can judge the suggestion.
  final String detail;

  /// A one-line description for the review list.
  String get summary =>
      [if (value.isNotEmpty) value, if (detail.isNotEmpty) detail].join(' · ');
}

/// What the vendor is asked for.
///
/// Names the closed set rather than inviting free-form structure, and says
/// outright not to guess: a CV that does not mention somebody's hair should
/// not produce a hair colour, and a plausible invention is worse than a gap
/// because nothing downstream can tell them apart.
String autofillPrompt(String documentText) => '''
Read the document below and pull out facts about the person it describes.

Reply with JSON only, in this shape:
{"suggestions":[{"target":"job","label":"Acme Ltd","value":"Engineer","detail":"2015-2019"}]}

"target" must be one of: bio, trait, customField, group, education, job,
place, tag.
- bio: a one or two sentence summary. "label" is "bio", "value" is the text.
- trait: label is one of hair, eyes, height, build, handed, languages, diet,
  contact. value is the answer.
- customField: any other named fact. label is the name, value is the answer.
- group: an employer, school or club they belong to. label is its name.
- education: label is the school, value is the subject or degree, detail is
  the years.
- job: label is the employer, value is the role, detail is the years.
- place: label is somewhere they have lived.
- tag: a one-word impression. label is the word, value empty.

Only what the document actually says. Do not guess, do not infer, and leave
anything out rather than filling it in. Omit "suggestions" entries you are not
confident about.

Document:
$documentText''';

/// Reads the reply. Anything unrecognised is dropped rather than guessed at —
/// a reply this cannot make sense of should produce a short list, not a wrong
/// one.
List<ProfileSuggestion> parseAutofill(String reply) {
  try {
    final start = reply.indexOf('{');
    final end = reply.lastIndexOf('}');
    if (start < 0 || end <= start) return const [];
    final body = jsonDecode(reply.substring(start, end + 1));
    if (body is! Map) return const [];
    final raw = body['suggestions'];
    if (raw is! List) return const [];
    final out = <ProfileSuggestion>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final target = SuggestionTarget.values
          .where((t) => t.name == item['target'])
          .firstOrNull;
      if (target == null) continue;
      final label = '${item['label'] ?? ''}'.trim();
      if (label.isEmpty) continue;
      out.add(
        ProfileSuggestion(
          target: target,
          label: label,
          value: '${item['value'] ?? ''}'.trim(),
          detail: '${item['detail'] ?? ''}'.trim(),
        ),
      );
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// Plain text out of whatever was picked.
///
/// Only what decodes as text. A PDF or a Word file is a container this app has
/// no parser for, and sending its raw bytes to a vendor would spend money to
/// be told it is unreadable — so it says so instead.
String? documentText(List<int> bytes) {
  try {
    final text = utf8.decode(bytes, allowMalformed: false);
    return text.trim().isEmpty ? null : text;
  } catch (_) {
    return null;
  }
}

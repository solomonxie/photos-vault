import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/profile_autofill.dart';

void main() {
  test('reads the suggestions it understands', () {
    final parsed = parseAutofill('''
      {"suggestions":[
        {"target":"job","label":"Acme Ltd","value":"Engineer","detail":"2015-2019"},
        {"target":"tag","label":"organised"}
      ]}
    ''');

    expect(parsed, hasLength(2));
    expect(parsed.first.target, SuggestionTarget.job);
    expect(parsed.first.label, 'Acme Ltd');
    expect(parsed.first.summary, 'Engineer · 2015-2019');
    expect(parsed.last.target, SuggestionTarget.tag);
    expect(parsed.last.summary, isEmpty);
  });

  test('prose around the JSON does not stop it', () {
    // Vendors preface a reply with a sentence more often than not.
    final parsed = parseAutofill(
      'Sure! Here is what I found:\n'
      '{"suggestions":[{"target":"place","label":"Kyoto"}]}\n'
      'Let me know if you want more.',
    );

    expect(parsed.single.label, 'Kyoto');
  });

  test('a target it has never heard of is dropped, not guessed', () {
    final parsed = parseAutofill(
      '{"suggestions":[{"target":"astrology","label":"Leo"},'
      '{"target":"place","label":"Kyoto"}]}',
    );

    expect(parsed.map((s) => s.label), ['Kyoto']);
  });

  test('a suggestion with nothing to call it is dropped', () {
    final parsed = parseAutofill(
      '{"suggestions":[{"target":"job","label":"  ","value":"Engineer"}]}',
    );

    expect(parsed, isEmpty);
  });

  test('a reply that is not JSON at all is an empty list, not a crash', () {
    for (final reply in [
      '',
      'I cannot help with that.',
      '{not json}',
      '{"suggestions":"lots"}',
      '[]',
    ]) {
      expect(parseAutofill(reply), isEmpty, reason: reply);
    }
  });

  test('the prompt carries the document and names the closed set', () {
    final prompt = autofillPrompt('Mia worked at Acme.');

    expect(prompt, contains('Mia worked at Acme.'));
    for (final target in SuggestionTarget.values) {
      expect(prompt, contains(target.name), reason: target.name);
    }
    // The instruction that matters most: a plausible invention is worse than
    // a gap, because nothing downstream can tell them apart.
    expect(prompt, contains('Do not guess'));
  });
}

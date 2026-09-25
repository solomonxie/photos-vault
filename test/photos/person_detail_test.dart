import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/photos/person_detail.dart';
import 'package:photos_vault/vault/keys.dart';

AlbumKeys _keysFor(int seed) => AlbumKeys(
  albumKey: Uint8List.fromList(List.generate(32, (i) => (i * seed + 7) % 256)),
  entry: PassphraseEntry(
    id: 'entry$seed',
    salt: Uint8List(16),
    verifier: Uint8List(32),
    hint: 'hint $seed',
  ),
);

const _detail = PersonDetail(
  bio: 'Met at the climbing gym.',
  gender: Gender.female,
  customFields: [PersonCustomField(label: 'Coffee', value: 'Oat flat white')],
  impression: PersonImpression(
    overall: ImpressionLevel.high,
    socialEnergy: ImpressionLevel.veryHigh,
    introversion: ImpressionLevel.low,
    tags: ['funny', 'generous'],
  ),
  hint: 'gym friends',
);

void main() {
  test('a sealed set comes back whole under the same keys', () {
    final seal = PersonDetailSeal();
    final keys = _keysFor(1);

    final opened = seal.open(seal.seal(_detail, keys), keys)!;

    expect(opened.bio, 'Met at the climbing gym.');
    expect(opened.gender, Gender.female);
    expect(opened.customFields.single.value, 'Oat flat white');
    expect(opened.impression.overall, ImpressionLevel.high);
    expect(opened.impression.tags, ['funny', 'generous']);
    expect(opened.hint, 'gym friends');
  });

  test('another passcode opens nothing, and that is not an error', () {
    final seal = PersonDetailSeal();

    // Different digits derive a different album key. The payload is there,
    // the MAC does not verify, and the answer is the same as for a set
    // nobody has ever written to: nothing.
    expect(seal.open(seal.seal(_detail, _keysFor(1)), _keysFor(2)), isNull);
  });

  test('a row that is not ours is nothing, not a crash', () {
    final seal = PersonDetailSeal();

    for (final payload in ['', 'not base64 !!', 'aGVsbG8=']) {
      expect(seal.open(payload, _keysFor(1)), isNull, reason: payload);
    }
  });

  test('sealing twice gives different bytes for the same set', () {
    final seal = PersonDetailSeal();
    final keys = _keysFor(3);

    // A fresh IV each time, so two profiles holding the same details do not
    // announce it by holding identical rows.
    expect(seal.seal(_detail, keys), isNot(seal.seal(_detail, keys)));
  });

  test('the empty set is empty, and a hint alone is not', () {
    expect(PersonDetail.empty.isEmpty, isTrue);
    expect(const PersonDetail(hint: 'work').isEmpty, isFalse);
    expect(const PersonImpression().isEmpty, isTrue);
    expect(const PersonImpression(tags: ['funny']).isEmpty, isFalse);
  });

  test('an unknown level or tag shape decodes to nothing, not a throw', () {
    final decoded = PersonDetail.fromJson(const {
      'bio': 'kept',
      'gender': 'nonsense',
      'impression': {'overall': 'nonsense', 'tags': []},
    });

    expect(decoded.bio, 'kept');
    expect(decoded.gender, isNull);
    expect(decoded.impression.overall, isNull);
  });
}

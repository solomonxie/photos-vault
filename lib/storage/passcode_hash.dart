import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The old tag: unsalted SHA-256 of the code. Ten thousand tries reverse
/// it, so it is only ever read now — to find what still carries it and
/// move it to [passcodeTagWith]. See `../vault/passcode_tags.dart`.
String hashPasscode(String passcode) =>
    sha256.convert(utf8.encode(passcode)).toString();

const tagPrefix = 't1:';

/// What a hidden album, a person's hidden folder and a sealed profile set
/// are stored under: HMAC of the code under a key only the keychain holds.
String passcodeTagWith(List<int> key, String passcode) =>
    '$tagPrefix${Hmac(sha256, key).convert(utf8.encode(passcode))}';

bool isLegacyTag(String tag) => tag.isNotEmpty && !tag.startsWith(tagPrefix);

/// Which legacy tags in [legacy] reverse to which code, among the four-digit
/// codes and each of [personIds]' folder codes. Pure, for an isolate.
Map<String, String> reverseLegacyTags(
  Set<String> legacy,
  List<String> personIds,
) {
  final found = <String, String>{};
  bool tryCode(String code) {
    final tag = hashPasscode(code);
    if (legacy.contains(tag)) found[tag] = code;
    return found.length == legacy.length;
  }

  for (var i = 0; i < 10000; i++) {
    if (tryCode(i.toString().padLeft(4, '0'))) return found;
  }
  for (final id in personIds) {
    for (var i = 0; i < 10000; i++) {
      final digits = i.toString().padLeft(4, '0');
      if (tryCode(personAlbumCode(id, digits))) return found;
    }
  }
  return found;
}

/// A person's own hidden folder: the digits namespaced by the person, so
/// the same four digits open a different album per person.
String personAlbumCode(String personId, String digits) =>
    'person:$personId:$digits';

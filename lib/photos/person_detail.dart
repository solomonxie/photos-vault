import 'dart:convert';
import 'dart:typed_data';

import '../vault/carrier.dart' show randomBytes;
import '../vault/cipher.dart';
import '../vault/keys.dart';
import 'person.dart';

/// Everything on a profile below the name: kept per passcode, not per
/// person.
///
/// A person has one identity — their name, their face, their photos — and
/// as many sets of details as there are passcodes typed at their profile.
/// No passcode is the open set, and anything else is its own, empty until
/// something is written there. Nothing is ever checked, so nothing can be
/// wrong: the same keypad that opens a full profile opens an empty one, and
/// neither says which it did.
///
/// Held as one record rather than as columns because it is always read and
/// written whole, and because once sealed it is opaque bytes — columns
/// would describe a shape nothing can see.
class PersonDetail {
  const PersonDetail({
    this.bio = '',
    this.birthDate,
    this.gender,
    this.customFields = const [],
    this.impression = const PersonImpression(),
    this.hint = '',
  });

  final String bio;
  final DateTime? birthDate;
  final Gender? gender;

  /// "More details" — user-defined label/value pairs.
  final List<PersonCustomField> customFields;

  final PersonImpression impression;

  /// A reminder of *which* set this is, shown only once you are already
  /// inside it. Outside, it would be proof that the set exists.
  final String hint;

  static const empty = PersonDetail();

  bool get isEmpty =>
      bio.isEmpty &&
      birthDate == null &&
      gender == null &&
      customFields.isEmpty &&
      impression.isEmpty &&
      hint.isEmpty;

  PersonDetail copyWith({
    String? bio,
    DateTime? Function()? birthDate,
    Gender? Function()? gender,
    List<PersonCustomField>? customFields,
    PersonImpression? impression,
    String? hint,
  }) => PersonDetail(
    bio: bio ?? this.bio,
    birthDate: birthDate != null ? birthDate() : this.birthDate,
    gender: gender != null ? gender() : this.gender,
    customFields: customFields ?? this.customFields,
    impression: impression ?? this.impression,
    hint: hint ?? this.hint,
  );

  Map<String, Object?> toJson() => {
    'bio': bio,
    'birthDate': birthDate?.millisecondsSinceEpoch,
    'gender': gender?.name,
    'customFields': [for (final f in customFields) f.toJson()],
    'impression': impression.toJson(),
    'hint': hint,
  };

  static PersonDetail fromJson(Map<String, Object?> json) {
    final birth = json['birthDate'] as int?;
    final gender = json['gender'] as String?;
    return PersonDetail(
      bio: json['bio'] as String? ?? '',
      birthDate: birth == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(birth),
      gender: Gender.values.where((g) => g.name == gender).firstOrNull,
      customFields: [
        for (final f in (json['customFields'] as List? ?? const []))
          PersonCustomField.fromJson((f as Map).cast<String, Object?>()),
      ],
      impression: PersonImpression.fromJson(
        ((json['impression'] as Map?) ?? const {}).cast<String, Object?>(),
      ),
      hint: json['hint'] as String? ?? '',
    );
  }
}

/// What someone is like, as the person keeping the profile sees them.
///
/// Impressions, not assessments. The scales are the ones a reader already
/// has words for — how they come across, how much company they want — and
/// the tags carry the rest without naming a model or implying a diagnosis.
/// Everything is optional and nothing is scored.
enum ImpressionLevel { veryLow, low, middle, high, veryHigh }

class PersonImpression {
  const PersonImpression({
    this.overall,
    this.socialEnergy,
    this.introversion,
    this.tags = const [],
  });

  /// Negative → very positive.
  final ImpressionLevel? overall;

  /// Very reserved → very outgoing.
  final ImpressionLevel? socialEnergy;

  /// Strongly introvert → strongly extrovert.
  final ImpressionLevel? introversion;

  final List<String> tags;

  bool get isEmpty =>
      overall == null &&
      socialEnergy == null &&
      introversion == null &&
      tags.isEmpty;

  PersonImpression copyWith({
    ImpressionLevel? Function()? overall,
    ImpressionLevel? Function()? socialEnergy,
    ImpressionLevel? Function()? introversion,
    List<String>? tags,
  }) => PersonImpression(
    overall: overall != null ? overall() : this.overall,
    socialEnergy: socialEnergy != null ? socialEnergy() : this.socialEnergy,
    introversion: introversion != null ? introversion() : this.introversion,
    tags: tags ?? this.tags,
  );

  Map<String, Object?> toJson() => {
    'overall': overall?.name,
    'socialEnergy': socialEnergy?.name,
    'introversion': introversion?.name,
    'tags': tags,
  };

  static PersonImpression fromJson(Map<String, Object?> json) {
    ImpressionLevel? level(String key) => ImpressionLevel.values
        .where((l) => l.name == json[key] as String?)
        .firstOrNull;
    return PersonImpression(
      overall: level('overall'),
      socialEnergy: level('socialEnergy'),
      introversion: level('introversion'),
      tags: [for (final t in (json['tags'] as List? ?? const [])) t as String],
    );
  }
}

/// What kind of occasion an event was.
///
/// [firstMet] is special: every profile has exactly one, it cannot be
/// deleted, and it is not written to the database until a date is put on it.
/// A blank row reads as a prompt; a row the app invented and dated from the
/// earliest photo would read as a record, and be wrong.
enum PersonEventType {
  firstMet,
  reunion,
  trip,
  celebration,
  milestone,
  favour,
  fallingOut,
  other,
}

/// Something that happened with somebody, on a date, with notes.
class PersonEvent {
  const PersonEvent({
    required this.id,
    required this.personId,
    required this.type,
    this.at,
    this.tags = const [],
    this.notes = '',
  });

  final String id;
  final String personId;
  final PersonEventType type;

  /// Null only for the unwritten [PersonEventType.firstMet] prompt.
  final DateTime? at;
  final List<String> tags;
  final String notes;

  bool get isFirstMet => type == PersonEventType.firstMet;

  PersonEvent copyWith({
    PersonEventType? type,
    DateTime? Function()? at,
    List<String>? tags,
    String? notes,
  }) => PersonEvent(
    id: id,
    personId: personId,
    type: type ?? this.type,
    at: at != null ? at() : this.at,
    tags: tags ?? this.tags,
    notes: notes ?? this.notes,
  );

  Map<String, Object?> toJson() => {
    'type': type.name,
    'at': at?.millisecondsSinceEpoch,
    'tags': tags,
    'notes': notes,
  };

  static PersonEvent fromJson(
    String id,
    String personId,
    Map<String, Object?> json,
  ) {
    final at = json['at'] as int?;
    return PersonEvent(
      id: id,
      personId: personId,
      type:
          PersonEventType.values
              .where((t) => t.name == json['type'] as String?)
              .firstOrNull ??
          PersonEventType.other,
      at: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
      tags: [for (final t in (json['tags'] as List? ?? const [])) t as String],
      notes: json['notes'] as String? ?? '',
    );
  }
}

/// The twelve offered as chips. Free-form is deliberately not offered: a
/// typed word is a note, and notes belong in About.
const impressionTags = [
  'curious',
  'organised',
  'spontaneous',
  'empathetic',
  'blunt',
  'patient',
  'competitive',
  'generous',
  'private',
  'funny',
  'steady',
  'intense',
];

/// The open set — what a profile shows before any passcode is typed.
const openNamespace = '';

/// Seals and opens a namespace's payload under the key the 4 digits produce.
///
/// The key is the private album's, for the same 4 digits: a passphrase
/// stretched to a master key in the keychain, then HKDF'd with the digits.
/// Digits alone would be ten thousand guesses against a backup zip, which
/// is no protection at all once the zip is out of iCloud Drive; this way
/// the zip is worthless without the passphrase, and the passphrase never
/// leaves the phone.
///
/// The open set is not sealed. It is the profile everybody already sees.
class PersonDetailSeal {
  PersonDetailSeal({VaultCipher? cipher})
    : _cipher = cipher ?? PlatformCipher();

  final VaultCipher _cipher;

  /// `iv(16) ‖ ciphertext ‖ mac(32)`, base64 — the same shape the carrier
  /// and the cache use, for the same reason: encrypt-then-MAC, and a
  /// failed MAC is indistinguishable from a set nobody has written to.
  String seal(PersonDetail detail, AlbumKeys keys) =>
      sealJson(detail.toJson(), keys);

  /// The same envelope around any row's content. Education, job, places and
  /// relationships go through this too: outside the open set a row keeps
  /// only what a query needs — whose it is, and which passcode — and
  /// everything it *says* lives in here.
  String sealJson(Map<String, Object?> content, AlbumKeys keys) {
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(content)));
    final iv = randomBytes(16);
    final body = _cipher.transform(
      key: keys.carrier.encKey,
      iv: iv,
      data: plain,
    );
    return base64Encode([
      ...iv,
      ...body,
      ...vaultHmac(keys.carrier.macKey, [...iv, ...body]),
    ]);
  }

  /// `null` for a payload these keys don't open — a different passcode, a
  /// different passphrase, or a truncated row. The caller shows an empty
  /// set, which is also what an unused passcode shows.
  PersonDetail? open(String payload, AlbumKeys keys) {
    final json = openJson(payload, keys);
    return json == null ? null : PersonDetail.fromJson(json);
  }

  Map<String, Object?>? openJson(String payload, AlbumKeys keys) {
    try {
      final bytes = base64Decode(payload);
      if (bytes.length <= 48) return null;
      final iv = Uint8List.sublistView(bytes, 0, 16);
      final body = Uint8List.sublistView(bytes, 16, bytes.length - 32);
      final mac = Uint8List.sublistView(bytes, bytes.length - 32);
      if (!bytesMatch(vaultHmac(keys.carrier.macKey, [...iv, ...body]), mac)) {
        return null;
      }
      return (jsonDecode(
        utf8.decode(
          _cipher.transform(key: keys.carrier.encKey, iv: iv, data: body),
        ),
      ) as Map).cast<String, Object?>();
    } catch (_) {
      // Not base64, not JSON, not ours.
      return null;
    }
  }
}

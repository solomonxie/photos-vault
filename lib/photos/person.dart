/// Where a face sits in a photo, as fractions of its width and height with
/// the origin at the top left. Small enough to keep on the person rather
/// than cropping and storing a second image.
class FaceRect {
  const FaceRect(this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;

  /// `x,y,w,h` — one column, and readable in a database browser.
  String encode() => '$x,$y,$width,$height';

  static FaceRect? decode(String? value) {
    if (value == null) return null;
    final parts = value.split(',');
    if (parts.length != 4) return null;
    final numbers = parts.map(double.tryParse).toList();
    if (numbers.any((n) => n == null)) return null;
    return FaceRect(numbers[0]!, numbers[1]!, numbers[2]!, numbers[3]!);
  }

  @override
  bool operator ==(Object other) =>
      other is FaceRect &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);
}

/// One face the app found, in the photo it found it in, that nobody has
/// put a name to. Not a [Person] and deliberately not stored as one —
/// there is nothing to remember about it beyond "here, look at this".
class UnnamedFace {
  const UnnamedFace({
    required this.localId,
    required this.face,
    this.suggestedPersonId,
    this.suggestedName,
    this.alike = 1,
  });

  final String localId;
  final FaceRect face;

  /// Who the app thinks this is, if it has an opinion. A guess, offered —
  /// never a link made. Null is the normal case and a fine answer.
  final String? suggestedPersonId;
  final String? suggestedName;

  /// How many faces this one stands for, itself included.
  ///
  /// The list shows one circle per *person*, not per face — three photos
  /// of the same stranger asked "who's this?" three times, which is three
  /// answers for one question. This is the size of the pile behind the
  /// one on top.
  final int alike;

  bool get hasSuggestion => suggestedName != null;
}

/// How two [Person]s relate — drives both the profile's relationship list
/// and the net graph's line color/style (T7.5/T7.6). `family`/`spouse`/
/// `parent`/`child`/`sibling` cluster together in the graph's family circle;
/// `friend`/`colleague`/`schoolmate`/`other` are drawn as plain cross-cluster
/// lines.
enum RelationshipType {
  family,
  spouse,
  parent,
  child,
  sibling,
  friend,
  colleague,
  schoolmate,
  other,
}

bool isFamilyRelationship(RelationshipType type) => switch (type) {
  RelationshipType.family ||
  RelationshipType.spouse ||
  RelationshipType.parent ||
  RelationshipType.child ||
  RelationshipType.sibling => true,
  RelationshipType.friend ||
  RelationshipType.colleague ||
  RelationshipType.schoolmate ||
  RelationshipType.other => false,
};

/// The relationships that follow from people sharing a group.
///
/// Derived, never stored. A group says its members are family, or colleagues,
/// or schoolmates — so the links are a restatement of the membership, and
/// writing them down would mean 190 rows for a company of twenty and 190 to
/// unpick when one of them leaves. Leave the group and the link goes with it,
/// which is the behaviour anybody would expect and the one storing it cannot
/// give.
///
/// [members] is each group and who is in it. Explicitly-created relationships
/// win: somebody recorded as a `spouse` who is also in the family group stays
/// a spouse rather than being flattened to `family`.
List<PersonRelationship> groupRelationships({
  required String personId,
  required Map<PersonGroup, List<String>> members,
  Iterable<PersonRelationship> explicit = const [],
}) {
  final already = {for (final r in explicit) r.relatedPersonId};
  final out = <String, PersonRelationship>{};
  for (final entry in members.entries) {
    if (!entry.value.contains(personId)) continue;
    for (final other in entry.value) {
      if (other == personId || already.contains(other)) continue;
      // First group wins for a pair in two groups. Arbitrary, and better than
      // showing the same two people twice under different labels.
      out.putIfAbsent(
        other,
        () => PersonRelationship(
          personId: personId,
          relatedPersonId: other,
          type: relationshipForGroup(entry.key.kind),
          organization: entry.key.kind == GroupKind.circle
              ? null
              : entry.key.name,
        ),
      );
    }
  }
  return out.values.toList();
}

/// Everyone reachable from [personId] by following relationships in either
/// direction, including [personId] itself.
///
/// Relationships are stored with a direction — who was added to whose
/// profile — but nobody means it that way: if Mia is Daniel's colleague
/// then Daniel is reachable from Mia. So the walk ignores which end a row
/// was written from.
Set<String> peopleConnectedTo(
  String personId,
  Iterable<PersonRelationship> relationships,
) {
  final neighbours = <String, List<String>>{};
  for (final relationship in relationships) {
    (neighbours[relationship.personId] ??= []).add(
      relationship.relatedPersonId,
    );
    (neighbours[relationship.relatedPersonId] ??= []).add(
      relationship.personId,
    );
  }
  final reached = {personId};
  final pending = [personId];
  while (pending.isNotEmpty) {
    for (final next in neighbours[pending.removeLast()] ?? const <String>[]) {
      if (reached.add(next)) pending.add(next);
    }
  }
  return reached;
}

/// `colleague` (company), `schoolmate` (school), and `other` (church/other
/// org) each carry an associated [PersonRelationship.organization].
bool relationshipNeedsOrganization(RelationshipType type) =>
    type == RelationshipType.colleague ||
    type == RelationshipType.schoolmate ||
    type == RelationshipType.other;

/// A named set of people — a family, a company, a class, a circle of friends.
///
/// [kind] is what the group *means*, and it is the whole reason a group is
/// more than a label: everybody in a family group is family to everybody else
/// in it, so the links follow from the membership rather than being drawn one
/// by one. Twenty colleagues would otherwise be 190 relationships to enter by
/// hand, and 190 to unpick when somebody changes job.
enum GroupKind { family, company, school, circle }

/// The relationship shared-group membership implies. `circle` means friends,
/// which is the honest reading of a group somebody made and did not label.
RelationshipType relationshipForGroup(GroupKind kind) => switch (kind) {
  GroupKind.family => RelationshipType.family,
  GroupKind.company => RelationshipType.colleague,
  GroupKind.school => RelationshipType.schoolmate,
  GroupKind.circle => RelationshipType.friend,
};

class PersonGroup {
  const PersonGroup({required this.id, required this.name, required this.kind});

  final String id;
  final String name;
  final GroupKind kind;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'kind': kind.name};

  static PersonGroup fromJson(Map<String, Object?> json) => PersonGroup(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    kind:
        GroupKind.values
            .where((k) => k.name == json['kind'] as String?)
            .firstOrNull ??
        GroupKind.circle,
  );
}

/// Where a [Person] has lived — an origin or a relocation, never a trip.
/// See DESIGN.md: explicitly excludes travel/vacation history.
enum LocationKind { origin, relocation }

enum Gender { male, female }

/// A recognized, named person — more than the AI-vision people-*count*
/// grouping (`SmartCollectionScreen`): a persistent identity with its own
/// editable profile. See IMPLEMENTATION_PLAN.md Phase 7.
class Person {
  const Person({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.avatarLocalId,
    this.avatarFace,
    this.bio = '',
    this.birthDate,
    this.gender,
    this.customFields = const [],
    this.locked = false,
    this.passcodeHash,
    this.passcodeHint,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// `AssetRecord.localId` of the photo used as the profile picture — one of
  /// their own tagged photos, not a separately uploaded avatar.
  final String? avatarLocalId;

  /// Which face in that photo is *them*, as a normalised `x,y,w,h` rect.
  ///
  /// Without it a group shot gives everyone in it the same picture, and
  /// whoever happens to be centre-frame becomes the face of all of them.
  /// Null means "show the whole photo", which is right for an avatar that
  /// didn't come from tapping a face.
  final FaceRect? avatarFace;

  final String bio;

  /// Stored as a birth date (not a raw age number) so the displayed age
  /// stays correct without re-entering it — see [PersonProfileScreen]'s age
  /// row.
  final DateTime? birthDate;
  final Gender? gender;
  final List<PersonCustomField> customFields;

  /// When `true`, [PersonProfileScreen] hides [bio], [birthDate], [gender],
  /// [customFields], and the Education/Job [PersonHistoryEntry] lists until
  /// unlocked with [passcodeHash] — their tagged photos stay visible either
  /// way (see DESIGN.md's risk note on lock scope).
  final bool locked;
  final String? passcodeHash;
  final String? passcodeHint;

  Person copyWith({
    String? name,
    String? avatarLocalId,

    // Closure-wrapped so a new profile photo can clear the old one's face
    // box — keeping it would crop the new photo to where the face was in a
    // different one.
    FaceRect? Function()? avatarFace,
    String? bio,
    DateTime? Function()? birthDate,
    Gender? Function()? gender,
    List<PersonCustomField>? customFields,
    bool? locked,
    String? Function()? passcodeHash,
    String? Function()? passcodeHint,
  }) => Person(
    id: id,
    name: name ?? this.name,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
    avatarLocalId: avatarLocalId ?? this.avatarLocalId,
    avatarFace: avatarFace != null ? avatarFace() : this.avatarFace,
    bio: bio ?? this.bio,
    birthDate: birthDate != null ? birthDate() : this.birthDate,
    gender: gender != null ? gender() : this.gender,
    customFields: customFields ?? this.customFields,
    locked: locked ?? this.locked,
    passcodeHash: passcodeHash != null ? passcodeHash() : this.passcodeHash,
    passcodeHint: passcodeHint != null ? passcodeHint() : this.passcodeHint,
  );
}

/// Whole-years age as of today — `null` if [Person.birthDate] isn't set.
int? ageFrom(DateTime? birthDate) {
  if (birthDate == null) return null;
  final now = DateTime.now();
  var age = now.year - birthDate.year;
  if (now.month < birthDate.month ||
      (now.month == birthDate.month && now.day < birthDate.day)) {
    age--;
  }
  return age;
}

/// A directed link from one [Person] to another — the graph screen renders
/// it as a single undirected edge, styled by [type].
class PersonRelationship {
  const PersonRelationship({
    required this.personId,
    required this.relatedPersonId,
    required this.type,
    this.organization,
  });

  final String personId;
  final String relatedPersonId;
  final RelationshipType type;

  /// The company/school/org connecting the two — only meaningful when
  /// [relationshipNeedsOrganization] is true for [type].
  final String? organization;
}

/// One entry in a person's geolocation movement history.
class PersonLocation {
  const PersonLocation({
    required this.id,
    required this.personId,
    required this.kind,
    required this.place,
    required this.since,
  });

  final String id;
  final String personId;
  final LocationKind kind;
  final String place;
  final DateTime since;
}

/// Education or Job — a person can have several over a lifetime, so each is
/// its own entry (school/employer name, a time range, notes, and
/// user-defined custom fields), not a single string. See T7.3.
enum HistoryCategory { education, job }

/// A user-defined label/value pair attached to a [PersonHistoryEntry] — e.g.
/// "Degree" / "MBA", or "Title" / "Senior Engineer".
class PersonCustomField {
  const PersonCustomField({required this.label, required this.value});

  final String label;
  final String value;

  Map<String, Object?> toJson() => {'label': label, 'value': value};

  static PersonCustomField fromJson(Map<String, Object?> json) =>
      PersonCustomField(
        label: json['label'] as String? ?? '',
        value: json['value'] as String? ?? '',
      );
}

/// A role/title held at a job (or a major/degree at a school), or an award
/// — all three are just a name, an optional description, and an optional
/// date range. Shared shape, different section on the entry's detail page.
class TimelineEntry {
  const TimelineEntry({
    required this.id,
    required this.title,
    this.description = '',
    this.startDate,
    this.endDate,
  });

  final String id;
  final String title;
  final String description;
  final DateTime? startDate;

  /// `null` means "present" / still ongoing.
  final DateTime? endDate;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'startDate': startDate?.millisecondsSinceEpoch,
    'endDate': endDate?.millisecondsSinceEpoch,
  };

  static TimelineEntry fromJson(Map<String, Object?> json) {
    final start = json['startDate'] as int?;
    final end = json['endDate'] as int?;
    return TimelineEntry(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      startDate: start == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(start),
      endDate: end == null ? null : DateTime.fromMillisecondsSinceEpoch(end),
    );
  }
}

/// A project done during a job or while at school — like [TimelineEntry]
/// plus free-form tags.
class CareerProject {
  const CareerProject({
    required this.id,
    required this.name,
    this.description = '',
    this.tags = const [],
    this.startDate,
    this.endDate,
  });

  final String id;
  final String name;
  final String description;
  final List<String> tags;
  final DateTime? startDate;
  final DateTime? endDate;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'tags': tags,
    'startDate': startDate?.millisecondsSinceEpoch,
    'endDate': endDate?.millisecondsSinceEpoch,
  };

  static CareerProject fromJson(Map<String, Object?> json) {
    final start = json['startDate'] as int?;
    final end = json['endDate'] as int?;
    return CareerProject(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),
      startDate: start == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(start),
      endDate: end == null ? null : DateTime.fromMillisecondsSinceEpoch(end),
    );
  }
}

/// One school attended or job held.
class PersonHistoryEntry {
  const PersonHistoryEntry({
    required this.id,
    required this.personId,
    required this.category,
    required this.title,
    this.startDate,
    this.endDate,
    this.notes = '',
    this.customFields = const [],
    this.titles = const [],
    this.projects = const [],
    this.awards = const [],
  });

  final String id;
  final String personId;
  final HistoryCategory category;

  /// The school/employer name — picked from a searchable list of every
  /// title already used across the People registry, or typed fresh.
  final String title;

  final DateTime? startDate;

  /// `null` means "present" / still ongoing.
  final DateTime? endDate;

  final String notes;
  final List<PersonCustomField> customFields;

  /// Role/title changes over time at this job (or majors/degrees at this
  /// school) — the most recent one displays in place of [title] on the
  /// profile's Education/Job row.
  final List<TimelineEntry> titles;
  final List<CareerProject> projects;
  final List<TimelineEntry> awards;

  /// The latest [titles] entry (by start date, or the one still ongoing),
  /// or `null` if none have been added yet.
  TimelineEntry? get latestTitle {
    if (titles.isEmpty) return null;
    final ongoing = titles.where((t) => t.endDate == null).toList();
    if (ongoing.isNotEmpty) {
      ongoing.sort(
        (a, b) =>
            (b.startDate ?? DateTime(0)).compareTo(a.startDate ?? DateTime(0)),
      );
      return ongoing.first;
    }
    final sorted = [...titles]
      ..sort(
        (a, b) =>
            (b.startDate ?? DateTime(0)).compareTo(a.startDate ?? DateTime(0)),
      );
    return sorted.first;
  }

  PersonHistoryEntry copyWith({
    String? title,
    DateTime? Function()? startDate,
    DateTime? Function()? endDate,
    String? notes,
    List<PersonCustomField>? customFields,
    List<TimelineEntry>? titles,
    List<CareerProject>? projects,
    List<TimelineEntry>? awards,
  }) => PersonHistoryEntry(
    id: id,
    personId: personId,
    category: category,
    title: title ?? this.title,
    startDate: startDate != null ? startDate() : this.startDate,
    endDate: endDate != null ? endDate() : this.endDate,
    titles: titles ?? this.titles,
    projects: projects ?? this.projects,
    awards: awards ?? this.awards,
    notes: notes ?? this.notes,
    customFields: customFields ?? this.customFields,
  );
}

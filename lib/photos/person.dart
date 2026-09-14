/// How two [Person]s relate — drives both the profile's relationship list
/// and the net graph's line color/style (T7.5/T7.6). `family`/`spouse`/
/// `parent`/`child`/`sibling` cluster together in the graph's family circle;
/// `friend`/`colleague`/`schoolmate`/`other` are drawn as plain cross-cluster
/// lines.
enum RelationshipType { family, spouse, parent, child, sibling, friend, colleague, schoolmate, other }

bool isFamilyRelationship(RelationshipType type) => switch (type) {
  RelationshipType.family || RelationshipType.spouse || RelationshipType.parent ||
  RelationshipType.child || RelationshipType.sibling => true,
  RelationshipType.friend || RelationshipType.colleague || RelationshipType.schoolmate || RelationshipType.other => false,
};

/// `colleague` (company), `schoolmate` (school), and `other` (church/other
/// org) each carry an associated [PersonRelationship.organization].
bool relationshipNeedsOrganization(RelationshipType type) =>
    type == RelationshipType.colleague || type == RelationshipType.schoolmate || type == RelationshipType.other;

/// Where a [Person] has lived — an origin or a relocation, never a trip.
/// See DESIGN.md: explicitly excludes travel/vacation history.
enum LocationKind { origin, relocation }

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
    this.bio = '',
    this.locked = false,
    this.passcodeHash,
    this.passcodeHint,
    this.isDemo = false,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// `AssetRecord.localId` of the photo used as the profile picture — one of
  /// their own tagged photos, not a separately uploaded avatar.
  final String? avatarLocalId;

  final String bio;

  /// When `true`, [PersonProfileScreen] hides [bio] and the Education/Job
  /// [PersonHistoryEntry] lists until unlocked with [passcodeHash] — their
  /// tagged photos stay visible either way (see DESIGN.md's risk note on
  /// lock scope).
  final bool locked;
  final String? passcodeHash;
  final String? passcodeHint;

  /// Part of the bundled demo set — "Reset Demo Data" recreates it with the
  /// same [id] if deleted, same trick as `Album.isDemo`.
  final bool isDemo;

  Person copyWith({
    String? name,
    String? avatarLocalId,
    String? bio,
    bool? locked,
    String? Function()? passcodeHash,
    String? Function()? passcodeHint,
  }) => Person(
    id: id,
    name: name ?? this.name,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
    avatarLocalId: avatarLocalId ?? this.avatarLocalId,
    bio: bio ?? this.bio,
    locked: locked ?? this.locked,
    passcodeHash: passcodeHash != null ? passcodeHash() : this.passcodeHash,
    passcodeHint: passcodeHint != null ? passcodeHint() : this.passcodeHint,
    isDemo: isDemo,
  );
}

/// A directed link from one [Person] to another — the graph screen renders
/// it as a single undirected edge, styled by [type].
class PersonRelationship {
  const PersonRelationship({required this.personId, required this.relatedPersonId, required this.type, this.organization});

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
      PersonCustomField(label: json['label'] as String? ?? '', value: json['value'] as String? ?? '');
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

  PersonHistoryEntry copyWith({
    String? title,
    DateTime? Function()? startDate,
    DateTime? Function()? endDate,
    String? notes,
    List<PersonCustomField>? customFields,
  }) => PersonHistoryEntry(
    id: id,
    personId: personId,
    category: category,
    title: title ?? this.title,
    startDate: startDate != null ? startDate() : this.startDate,
    endDate: endDate != null ? endDate() : this.endDate,
    notes: notes ?? this.notes,
    customFields: customFields ?? this.customFields,
  );
}

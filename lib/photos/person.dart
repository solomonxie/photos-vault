/// How two [Person]s relate — drives both the profile's relationship list
/// and the net graph's line color/style (T7.5/T7.6). `family`/`spouse`/
/// `parent`/`child`/`sibling` cluster together in the graph's family circle;
/// `friend`/`colleague`/`other` are drawn as plain cross-cluster lines.
enum RelationshipType { family, spouse, parent, child, sibling, friend, colleague, other }

bool isFamilyRelationship(RelationshipType type) => switch (type) {
  RelationshipType.family || RelationshipType.spouse || RelationshipType.parent ||
  RelationshipType.child || RelationshipType.sibling => true,
  RelationshipType.friend || RelationshipType.colleague || RelationshipType.other => false,
};

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
    this.education = '',
    this.job = '',
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

  final String education;
  final String job;
  final String bio;

  /// When `true`, [PersonProfileScreen] hides [education]/[job]/[bio] until
  /// unlocked with [passcodeHash] — their tagged photos stay visible either
  /// way (see DESIGN.md's risk note on lock scope).
  final bool locked;
  final String? passcodeHash;
  final String? passcodeHint;

  /// Part of the bundled demo set — "Reset Demo Data" recreates it with the
  /// same [id] if deleted, same trick as `Album.isDemo`.
  final bool isDemo;

  Person copyWith({
    String? name,
    String? avatarLocalId,
    String? education,
    String? job,
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
    education: education ?? this.education,
    job: job ?? this.job,
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
  const PersonRelationship({required this.personId, required this.relatedPersonId, required this.type});

  final String personId;
  final String relatedPersonId;
  final RelationshipType type;
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

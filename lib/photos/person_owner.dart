import '../storage/asset_record_store.dart';
import 'person.dart';

/// Whose phone this is.
///
/// One [Person] among the rest rather than a special case beside them: the
/// owner gets tagged in photos, appears in the graph, and has a profile, all
/// through the machinery that already exists. A singleton living outside the
/// people table would have needed a parallel version of every one of those.
///
/// Kept in `app_state` next to the other app-level settings, so Remove All App
/// Data forgets it along with everything else it describes. Chosen in
/// Settings, or by the main page's Hidden the first time it is opened: the
/// owner's hidden folder is the one it opens (`owner_folder.dart`). It
/// rides in the app-data backup, and a change moves the backup's mark.
class PersonOwner {
  const PersonOwner(this.settings);

  final AssetRecordStore settings;

  static const key = 'owner_person_id';

  Future<String?> id() async {
    final stored = await settings.getAppState(key);
    return (stored == null || stored.isEmpty) ? null : stored;
  }

  Future<void> set(String? personId) async {
    if (await id() == personId) return;
    await settings.setAppState(key, personId ?? '');
    await settings.markChanged();
  }
}

/// How [relationships] say this person stands to the owner, in the words
/// somebody would actually use — "Your sister", not "Sibling".
///
/// Only direct links. A chain like "your wife's brother" is a different
/// feature and a longer one, and a profile two hops out saying nothing is
/// better than a profile saying something laboured.
List<RelationshipType> relationsToOwner({
  required String? ownerId,
  required Iterable<PersonRelationship> relationships,
}) {
  if (ownerId == null) return const [];
  final seen = <RelationshipType>{};
  for (final relationship in relationships) {
    if (relationship.relatedPersonId != ownerId) continue;
    seen.add(relationship.type);
  }
  return seen.toList();
}

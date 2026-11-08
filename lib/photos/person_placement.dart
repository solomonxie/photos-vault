import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'library_custody.dart';
import 'person_owner.dart';
import 'person_store.dart';

/// Whose a photo is ([AssetRecord.ownerId]) decides where it shows. The
/// owner's photos are the main library, the only one Photos mirrors;
/// anyone else's show on their page only and are held by this app, not
/// Photos. Who is *in* a photo (person tags) is a separate thing.
class PersonPlacement {
  PersonPlacement({
    required this.records,
    required this.people,
    LibraryCustody? custody,
  }) : _custodyGiven = custody;

  final AssetRecordStore records;
  final PersonStore people;
  final LibraryCustody? _custodyGiven;
  late final LibraryCustody _custody =
      _custodyGiven ?? LibraryCustody(store: records);

  Future<String?> _ownerId() => PersonOwner(records).id();

  Future<bool> isOwner(String personId) async => await _ownerId() == personId;

  /// Given to [personId] and on their page: out of the main library and
  /// Photos (copied here first, one OS prompt). The owner's are the main
  /// library, so for them it comes back into it.
  Future<void> keepFor(String personId, List<String> ids) async {
    if (ids.isEmpty) return;
    await people.addAssets(personId, ids);
    await giveTo(personId, ids);
  }

  /// Ownership alone, no tag: to [personId] (null or the owner: the main
  /// library and Photos), to anyone else out of Photos.
  Future<void> giveTo(String? personId, List<String> ids) async {
    if (ids.isEmpty) return;
    if (personId == null || await isOwner(personId)) return toLibrary(ids);
    await records.setOwner(ids, personId);
    // Binned or hidden ones are out of Photos already.
    await _custody.takeOutMany([
      for (final r in await records.listOf(ids))
        if (r.isVisibleInLibrary) r,
    ]);
  }

  /// Whether un-hiding from [personId]'s folder goes to the main library
  /// (and Photos): the owner's folder, or one whose person isn't known.
  Future<bool> restoresToMain(String? personId) async =>
      personId == null || await isOwner(personId);

  /// Out of a hidden folder, owned by its person. Un-hiding already put an
  /// owner's photo back in Photos and left anyone else's out.
  Future<void> restoreTo(String? personId, List<String> ids) async {
    if (ids.isEmpty) return;
    if (await restoresToMain(personId)) {
      await records.setOwner([
        for (final r in await records.listOf(ids))
          if (!r.isMine) r.localId,
      ], null);
      return;
    }
    await people.addAssets(personId!, ids);
    await records.setOwner(ids, personId);
  }

  /// Someone else's back into the main library and Photos; the owner's
  /// as they are.
  Future<void> toLibrary(List<String> ids) async {
    final theirs = [
      for (final r in await records.listOf(ids))
        if (!r.isMine) r,
    ];
    if (theirs.isEmpty) return;
    await records.setOwner([for (final r in theirs) r.localId], null);
    // Binned or hidden ones stay out of Photos; recovering or un-hiding
    // decides that.
    for (final r in theirs.where((r) => r.isVisibleInLibrary)) {
      // A refusal leaves it this app's alone, still in the library here.
      await _custody.putBack(await records.getByLocalId(r.localId) ?? r);
    }
  }

  /// [from]'s photos to [to] — a merge, or a move of everything.
  Future<void> reassign(String from, String? to) async {
    final ids = [
      for (final r in await records.listAll())
        if (r.ownerId == from) r.localId,
    ];
    await giveTo(to, ids);
  }

  /// Photos kept the old way (archived + `peopleOnly`, before
  /// [AssetRecord.ownerId]) given an owner: the one person besides the
  /// owner tagged in them, else back to the owner's library and Photos.
  /// Idempotent and cheap once done: a restored old backup is converted
  /// the same way.
  Future<void> convertLegacy(List<AssetRecord> all) async {
    final legacy = [
      for (final r in all)
        if (r.peopleOnly) r,
    ];
    if (legacy.isEmpty) return;
    final owner = await _ownerId();
    final whoIn = <String, List<String>>{};
    final ids = {for (final r in legacy) r.localId};
    for (final MapEntry(key: person, value: photos)
        in (await people.allMemberships()).entries) {
      if (person == owner) continue;
      for (final id in photos) {
        if (ids.contains(id)) (whoIn[id] ??= []).add(person);
      }
    }
    final mine = <String>[];
    final byPerson = <String, List<String>>{};
    for (final r in legacy) {
      final who = whoIn[r.localId] ?? const [];
      if (who.length == 1) {
        (byPerson[who.single] ??= []).add(r.localId);
      } else {
        mine.add(r.localId);
      }
    }
    for (final MapEntry(key: person, value: photos) in byPerson.entries) {
      await records.setOwner(photos, person);
    }
    await toLibrary(mine);
  }
}

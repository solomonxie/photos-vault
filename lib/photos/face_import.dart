import 'package:path/path.dart' as p;

import '../storage/asset_record.dart';
import '../storage/asset_record_store.dart';
import 'ai_analysis_store.dart';
import 'face_analyzer.dart';
import 'face_file.dart';
import 'known_names.dart';
import 'person.dart';
import 'person_store.dart';
import 'profile_transfer.dart' show PersonMatches;

/// An imported box is a found face when they overlap by a third, or its
/// centre is inside the found one: RetinaFace and Vision boxes differ in
/// extent, so the 0.5 a rescan uses is too strict here.
bool boxesAgree(FaceRect imported, FaceRect found) {
  if (imported.overlap(found) >= 0.3) return true;
  final cx = imported.x + imported.width / 2;
  final cy = imported.y + imported.height / 2;
  return cx >= found.x &&
      cx <= found.x + found.width &&
      cy >= found.y &&
      cy <= found.y + found.height;
}

/// Which of [found] each of [imported] is, by index: the closest pair
/// first, each found face taken once. An imported box with none is left
/// out.
Map<int, int> matchBoxes(List<FaceRect> imported, List<FaceRect> found) {
  final pairs = [
    for (var i = 0; i < imported.length; i++)
      for (var j = 0; j < found.length; j++)
        if (boxesAgree(imported[i], found[j]))
          (i: i, j: j, score: imported[i].overlap(found[j])),
  ]..sort((a, b) => b.score.compareTo(a.score));
  final out = <int, int>{};
  final taken = <int>{};
  for (final pair in pairs) {
    if (out.containsKey(pair.i) || taken.contains(pair.j)) continue;
    out[pair.i] = pair.j;
    taken.add(pair.j);
  }
  return out;
}

/// One face the import will name: [personId] someone already in People,
/// or [newName] someone it makes. [added]: no face was found there, so the
/// box is the file's.
class FaceImportLink {
  const FaceImportLink({
    required this.localId,
    required this.face,
    this.personId,
    this.newName,
    this.added = false,
  });

  final String localId;
  final FaceRect face;
  final String? personId;
  final String? newName;
  final bool added;
}

/// An unnamed face the import puts in a group. [added] as for
/// [FaceImportLink].
class FaceImportGroupFace {
  const FaceImportGroupFace({
    required this.localId,
    required this.face,
    required this.groupId,
    this.added = false,
  });

  final String localId;
  final FaceRect face;
  final String groupId;
  final bool added;
}

/// A face the file names that the import leaves alone: named someone else
/// here ([appPersonId]), or a name [sharedBy] several people.
class FaceImportConflict {
  const FaceImportConflict({
    required this.photo,
    required this.fileName,
    this.appPersonId,
    this.appName,
    this.sharedBy = 0,
  });

  /// The file's key for the photo (or its hash).
  final String photo;
  final String fileName;
  final String? appPersonId;
  final String? appName;
  final int sharedBy;
}

/// What an import would do, shown before anything is written.
class FaceImportPlan {
  const FaceImportPlan({
    this.links = const [],
    this.grouped = const [],
    this.groups = const {},
    this.conflicts = const [],
    this.newPeople = const [],
    this.unchanged = 0,
    this.namedNotGrouped = 0,
    this.skippedPhotos = 0,
    this.unreadable = 0,
  });

  final List<FaceImportLink> links;
  final List<FaceImportGroupFace> grouped;

  /// The groups [grouped] are in, id → suggested name.
  final Map<String, String?> groups;
  final List<FaceImportConflict> conflicts;

  /// Names nobody here has, one spelling each.
  final List<String> newPeople;

  /// Faces already named the same here.
  final int unchanged;

  /// Grouped in the file but named here: left out of their group.
  final int namedNotGrouped;

  /// Photos not here, not shown, or not readable: one count, so a hidden
  /// photo is never told apart from a missing one.
  final int skippedPhotos;

  /// Entries the file had that couldn't be read.
  final int unreadable;
}

typedef FileFace = ({String photo, FaceFileFace face});

/// The file's photos by local id: the original's key stem first, its hash
/// failing that. [unknown] counts the photos matched to nothing.
({Map<String, List<FileFace>> photos, int unknown}) resolveFacePhotos(
  FaceFile file,
  Iterable<({String localId, String? key, String? hash})> originals,
) {
  final byStem = <String, String>{};
  final byHash = <String, String>{};
  for (final o in originals) {
    if (o.key case final key?) {
      byStem[p.basenameWithoutExtension(key)] = o.localId;
    }
    if (o.hash case final hash?) byHash[hash.toLowerCase()] = o.localId;
  }
  final photos = <String, List<FileFace>>{};
  var unknown = 0;
  for (final photo in file.photos) {
    final key = photo.key;
    final id =
        (key == null
            ? null
            : byStem[key] ?? byStem[p.basenameWithoutExtension(key)]) ??
        byHash[photo.sha256];
    if (id == null) {
      unknown++;
      continue;
    }
    final label = key ?? photo.sha256!;
    (photos[id] ??= []).addAll([
      for (final f in photo.faces) (photo: label, face: f),
    ]);
  }
  return (photos: photos, unknown: unknown);
}

/// What importing [photos] would do, against what the app already has:
/// [visible] the photos that may be named, [rows] their found faces,
/// [named] who is already put to which face, [groups] the file's groups.
FaceImportPlan planFaceImport({
  required Map<String, List<FileFace>> photos,
  required Set<String> visible,
  required Map<String, ({List<FaceRect> faces, bool legacy})> rows,
  required Map<String, Map<FaceRect, String>> named,
  required List<Person> people,
  KnownNames? known,
  Map<String, FaceFileGroup> groups = const {},
  int unknown = 0,
  int unreadable = 0,
}) {
  final matches = PersonMatches(people, known: known);
  final names = {for (final person in people) person.id: person.name};
  final links = <FaceImportLink>[];
  final grouped = <FaceImportGroupFace>[];
  final conflicts = <FaceImportConflict>[];
  final newPeople = <String, String>{};
  var unchanged = 0;
  var namedNotGrouped = 0;
  var skipped = unknown;
  for (final MapEntry(key: localId, value: entries) in photos.entries) {
    final row = rows[localId];
    if (!visible.contains(localId) || (row?.legacy ?? false)) {
      skipped++;
      continue;
    }
    final namedHere = named[localId] ?? const {};
    final found = [...?row?.faces];
    for (final face in namedHere.keys) {
      if (!found.contains(face)) found.add(face);
    }
    final pairs = matchBoxes([for (final e in entries) e.face.box], found);
    for (final (i, e) in entries.indexed) {
      final at = pairs[i];
      final face = at == null ? e.face.box : found[at];
      final already = at == null ? null : namedHere[face];
      if (e.face.group case final groupId?) {
        if (already != null) {
          namedNotGrouped++;
        } else {
          grouped.add(
            FaceImportGroupFace(
              localId: localId,
              face: face,
              groupId: groupId,
              added: at == null,
            ),
          );
        }
        continue;
      }
      final name = e.face.person!;
      final same = matches.of(name);
      if (same.length > 1) {
        conflicts.add(
          FaceImportConflict(
            photo: e.photo,
            fileName: name,
            sharedBy: same.length,
          ),
        );
        continue;
      }
      final personId = same.firstOrNull?.id;
      if (personId == null) {
        newPeople.putIfAbsent(name.trim().toLowerCase(), () => name.trim());
      }
      if (already == null) {
        links.add(
          FaceImportLink(
            localId: localId,
            face: face,
            personId: personId,
            newName: personId == null ? name.trim() : null,
            added: at == null,
          ),
        );
      } else if (already == personId) {
        unchanged++;
      } else {
        conflicts.add(
          FaceImportConflict(
            photo: e.photo,
            fileName: name,
            appPersonId: already,
            appName: names[already],
          ),
        );
      }
    }
  }
  return FaceImportPlan(
    links: links,
    grouped: grouped,
    groups: {
      for (final id in {for (final g in grouped) g.groupId})
        id: groups[id]?.suggest,
    },
    conflicts: conflicts,
    newPeople: newPeople.values.toList(),
    unchanged: unchanged,
    namedNotGrouped: namedNotGrouped,
    skippedPhotos: skipped,
    unreadable: unreadable,
  );
}

/// Puts a face file's names and groups to the library's faces: [plan]
/// reads, [commit] writes, and nothing is written in between — the one tap
/// on the summary is the "nothing linked without a tap" rule. [name] is
/// the same linking for a group named on Faces to Name.
class FaceImport {
  FaceImport({
    required this.personStore,
    required this.assetRecordStore,
    required this.analysisStore,
    this.analyzer,
  });

  final PersonStore personStore;
  final AssetRecordStore assetRecordStore;
  final AiAnalysisStore analysisStore;

  /// Describes the imported faces in the background, so they join the
  /// reference set.
  final FaceAnalyzer? analyzer;

  Future<FaceImportPlan> plan(FaceFile file) async {
    final resolved = resolveFacePhotos(
      file,
      await assetRecordStore.originalKeys(),
    );
    final ids = resolved.photos.keys.toList();
    final records = await assetRecordStore.getByLocalIds(ids);
    final people = await personStore.listAll();
    return planFaceImport(
      photos: resolved.photos,
      visible: {
        for (final r in records.values)
          if (nameable(r)) r.localId,
      },
      rows: await analysisStore.faceRowsOf(ids),
      named: await analysisStore.namedFacesOf(ids),
      people: people,
      known: await personStore.knownNames(people),
      groups: file.groups,
      unknown: resolved.unknown,
      unreadable: file.unreadable,
    );
  }

  /// May be named or grouped: shown in the library, and a still.
  static bool nameable(AssetRecord r) => r.isVisibleInLibrary && !r.isVideo;

  /// Writes [plan]: new people made, faces named and grouped, photos
  /// linked to their people the way naming a face does. Visibility is
  /// checked again — a photo hidden since the summary is left alone.
  Future<({int faces, int people, int grouped})> commit(
    FaceImportPlan plan,
  ) async {
    if (plan.links.isEmpty && plan.grouped.isEmpty) {
      return (faces: 0, people: 0, grouped: 0);
    }
    final records = await assetRecordStore.getByLocalIds({
      for (final l in plan.links) l.localId,
      for (final g in plan.grouped) g.localId,
    });
    bool shown(String localId) => switch (records[localId]) {
      final r? => nameable(r),
      null => false,
    };
    final people = await personStore.listAll();
    final byId = {for (final person in people) person.id: person};
    final matches = PersonMatches(
      people,
      known: await personStore.knownNames(people),
    );
    final made = <String, Person>{};
    final links = <FaceLink>[];
    final added = <String, List<FaceRect>>{};
    for (final l in plan.links) {
      if (!shown(l.localId)) continue;
      var personId = l.personId;
      if (personId == null) {
        final name = l.newName!;
        final key = name.toLowerCase();
        final same = matches.of(name);
        if (same.length > 1) continue;
        final person =
            made[key] ??
            same.firstOrNull ??
            (made[key] = await personStore.create(name: name));
        byId[person.id] = person;
        personId = person.id;
      }
      if (byId[personId] == null) continue;
      links.add((localId: l.localId, face: l.face, personId: personId));
      if (l.added) (added[l.localId] ??= []).add(l.face);
    }
    final grouped = <GroupedFace>[];
    for (final g in plan.grouped) {
      if (!shown(g.localId)) continue;
      grouped.add((localId: g.localId, face: g.face, groupId: g.groupId));
      if (g.added) (added[g.localId] ??= []).add(g.face);
    }
    final result = await analysisStore.importNamedFaces(
      links,
      added: added,
      grouped: grouped,
      groups: plan.groups,
    );
    await _linked(result, records);
    return (
      faces: result.linked.length,
      people: made.length,
      grouped: result.grouped,
    );
  }

  /// Names [faces] [personId]'s — a group named on Faces to Name — the
  /// way [commit] names a file's. Each leaves its group. Photos no longer
  /// shown are left alone. The faces named.
  Future<List<({String localId, FaceRect face})>> name(
    String personId,
    List<({String localId, FaceRect face})> faces,
  ) async {
    final records = await assetRecordStore.getByLocalIds(
      faces.map((f) => f.localId),
    );
    final result = await analysisStore.importNamedFaces([
      for (final f in faces)
        if (records[f.localId] case final r? when nameable(r))
          (localId: f.localId, face: f.face, personId: personId),
    ], clearAll: false);
    await _linked(result, records);
    return [for (final l in result.linked) (localId: l.localId, face: l.face)];
  }

  /// Takes back [name]: [faces] unnamed and in group [groupId] again, and
  /// off [personId]'s page where no other face of theirs put them there.
  Future<void> unname(
    String personId,
    String groupId,
    List<({String localId, FaceRect face})> faces,
  ) async {
    final gone = await analysisStore.returnToGroup(personId, groupId, faces);
    await personStore.removeFaceTags(personId, gone);
  }

  /// What naming a face does besides the face: the photo on the person's
  /// page, their Last seen, a picture if they have none, and the faces
  /// queued to be described.
  Future<void> _linked(
    FaceImportWrite result,
    Map<String, AssetRecord> records,
  ) async {
    final byPerson = <String, List<FaceLink>>{};
    for (final l in result.linked) {
      (byPerson[l.personId] ??= []).add(l);
    }
    for (final MapEntry(key: personId, value: faces) in byPerson.entries) {
      await personStore.addAssets(
        personId,
        {for (final f in faces) f.localId},
        fillAvatar: false,
        viaFace: true,
      );
      final person = await personStore.getById(personId);
      if (person != null && person.avatarLocalId == null) {
        await personStore.update(
          person.copyWith(
            avatarLocalId: faces.first.localId,
            avatarFace: () => faces.first.face,
          ),
        );
      }
    }
    if (result.linked.isNotEmpty) {
      analyzer?.add(result.undescribed);
    }
  }
}

/// [groups] as Faces to Name shows them: faces only from photos in
/// [records] (those that may be named), biggest first, empty ones gone.
List<StoredFaceGroup> shownFaceGroups(
  List<StoredFaceGroup> groups,
  Map<String, AssetRecord> records,
) {
  final out = [
    for (final g in groups)
      if ([
            for (final f in g.faces)
              if (records[f.localId] case final r? when FaceImport.nameable(r))
                f,
          ]
          case final faces when faces.isNotEmpty)
        StoredFaceGroup(id: g.id, suggest: g.suggest, faces: faces),
  ];
  return out..sort((a, b) => b.faces.length.compareTo(a.faces.length));
}

/// The groups waiting for a name, and the records their faces are drawn
/// from: three reads, whatever the number of groups.
Future<({List<StoredFaceGroup> groups, Map<String, AssetRecord> records})>
loadFaceGroups(AiAnalysisStore analysis, AssetRecordStore records) async {
  final groups = await analysis.faceGroups();
  if (groups.isEmpty) return (groups: groups, records: <String, AssetRecord>{});
  final shown = await records.getVisibleByLocalIds({
    for (final g in groups)
      for (final f in g.faces) f.localId,
  });
  return (groups: shownFaceGroups(groups, shown), records: shown);
}

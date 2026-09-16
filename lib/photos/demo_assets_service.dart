import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/passcode_hash.dart';
import 'file_hash.dart' as file_hash;
import 'manual_add.dart';
import 'person.dart';
import 'person_store.dart';

/// Ships a handful of tiny bundled photos/videos so the app is immediately
/// tryable — pick "Try with Demo Photos" and there's something to back up
/// without first hunting for a file or setting up S3.
///
/// Enqueueing goes through [ManualAddService], which keys `localId` off the
/// file's content hash — re-adding an already-present demo item is a no-op,
/// and re-adding one the user deleted (Settings' "Reset Demo Data") brings
/// it right back. `targetDirectory` here is just scratch space to
/// materialize the bundled bytes into a real file — [ManualAddService]
/// copies it into its own durable, app-owned storage from there, so this
/// one doesn't need to be persistent.
class DemoAssetsService {
  DemoAssetsService({
    required this.manualAddService,
    AlbumStore? albumStore,
    PersonStore? personStore,
    Future<Directory> Function()? targetDirectory,
  }) : albumStore = albumStore ?? AlbumStore(),
       personStore = personStore ?? PersonStore(),
       _targetDirectory = targetDirectory ?? getTemporaryDirectory;

  final ManualAddService manualAddService;
  final AlbumStore albumStore;
  final PersonStore personStore;
  final Future<Directory> Function() _targetDirectory;

  /// Demo Private Album passcode — documented here (not shown in-app; that
  /// would defeat the point) so "Reset Demo Data" has something to show off
  /// the Hidden/Private Albums feature with. Try entering `1234` on the
  /// Utilities "Hidden" row.
  static const demoPrivateAlbumPasscode = '1234';

  static final assetPaths = [
    for (var i = 1; i <= 50; i++)
      'assets/demo/demo_photo_${i.toString().padLeft(2, '0')}.jpg',
    'assets/demo/demo_video_1.mp4',
  ];

  /// Preset albums seeded from [assetPaths] by index range — same
  /// deterministic-id trick as the assets themselves: re-running [addAll]
  /// after a demo album is deleted (Settings' "Reset Demo Data") recreates
  /// it with the same membership, since `localId` is content-hash-derived
  /// and thus stable across resets.
  static const _demoAlbums = [
    (id: 'demo-album-nature', name: 'Nature', range: (0, 25)),
    (id: 'demo-album-city', name: 'City', range: (25, 50)),
    (id: 'demo-album-videos', name: 'Videos', range: (50, 51)),
  ];

  Future<List<AssetRecord>> addAll() async {
    final dir = await _targetDirectory();
    final demoDays = _demoDays(DateTime.now());
    final added = <AssetRecord>[];
    for (var i = 0; i < assetPaths.length; i++) {
      final assetPath = assetPaths[i];
      final data = await rootBundle.load(assetPath);
      final fileName = assetPath.split('/').last;
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      added.add(
        await manualAddService.enqueueFile(
          file.path,
          createdAt: demoDays[i % demoDays.length],
        ),
      );
    }
    await _seedDemoAlbums(added);
    await _seedDemoPrivateAlbum(added);
    await _seedDemoPeople(added);
    await _seedMarcusNetwork(added);
    return added;
  }

  /// Five fixed days spanning three different years — assets are distributed
  /// round-robin across these instead of each getting its own unique day, so
  /// the Library grid shows a handful of grouped days/years rather than one
  /// pile per item. Only applied on first insert (see
  /// `AssetRecordStore.upsert`), so a reset doesn't shuffle dates on items
  /// already present.
  static List<DateTime> _demoDays(DateTime now) => [
    DateTime(now.year, now.month, now.day),
    DateTime(now.year, now.month, now.day).subtract(const Duration(days: 45)),
    DateTime(now.year - 1, now.month, now.day),
    DateTime(
      now.year - 1,
      now.month,
      now.day,
    ).subtract(const Duration(days: 60)),
    DateTime(now.year - 2, now.month, now.day),
  ];

  /// The local ids [addAll] would create — the bundled files' own content
  /// hashes, which is what `ManualAddService` keys them by. Knowing them
  /// without re-adding anything is what lets demo data be *removed*
  /// exactly, rather than by guessing at filenames.
  Future<Set<String>> demoLocalIds() async {
    final ids = <String>{};
    for (final assetPath in assetPaths) {
      final data = await rootBundle.load(assetPath);
      ids.add(
        'manual:${file_hash.hashBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes))}',
      );
    }
    return ids;
  }

  /// Takes back everything [addAll] put in: the demo photos and videos,
  /// their copied files, the demo albums, and the demo people. Anything the
  /// user made themselves is untouched — demo albums and people carry an
  /// `isDemo` flag for exactly this, and the assets are found by the
  /// content hash of the bundled originals.
  Future<int> removeAll() async {
    var removed = 0;
    for (final localId in await demoLocalIds()) {
      final record = await manualAddService.store.getByLocalId(localId);
      if (record == null) continue;
      final path = record.sourcePath;
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {
          // Already gone, or never written — the record still goes.
        }
      }
      await manualAddService.store.remove(localId);
      removed++;
    }
    for (final album in await albumStore.listAll()) {
      if (album.isDemo) await albumStore.remove(album.id);
    }
    for (final person in await personStore.listAll()) {
      if (person.isDemo) await personStore.remove(person.id);
    }
    return removed;
  }

  Future<void> _seedDemoAlbums(List<AssetRecord> added) async {
    for (final spec in _demoAlbums) {
      final (start, end) = spec.range;
      await albumStore.upsert(id: spec.id, name: spec.name, isDemo: true);
      await albumStore.addAssets(
        spec.id,
        added.sublist(start, end).map((r) => r.localId),
      );
    }
  }

  /// A ready-to-open Private Album at [demoPrivateAlbumPasscode] — a few
  /// nature photos tagged with its passcode hash (hidden from the main
  /// library/Nature album, since there's no separate album entity to hold
  /// them: the shared hash *is* the album). Re-running after they've all
  /// been taken back out re-tags them, same "Reset Demo Data" trick as the
  /// albums above.
  Future<void> _seedDemoPrivateAlbum(List<AssetRecord> added) async {
    final hash = hashPasscode(demoPrivateAlbumPasscode);
    for (final record in added.sublist(5, 8)) {
      await manualAddService.store.setPasscodeHash(record.localId, hash);
    }
  }

  static const _demoPeople = [
    (
      id: 'demo-person-mia',
      name: 'Mia Chen',
      avatarIndex: 9,
      photoRange: (9, 12),
      education: 'UC Berkeley',
      job: 'Product Designer',
      bio: 'Loves hiking and film photography.',
    ),
    (
      id: 'demo-person-daniel',
      name: 'Daniel Wong',
      avatarIndex: 32,
      photoRange: (32, 35),
      education: 'University of Toronto',
      job: 'Software Engineer',
      bio: 'Mia\'s college friend, now based in the city.',
    ),
    (
      id: 'demo-person-grandma-lily',
      name: 'Grandma Lily',
      avatarIndex: 45,
      photoRange: (45, 47),
      education: '',
      job: 'Retired schoolteacher',
      bio: 'Raised the whole family in Guangzhou before relocating.',
    ),
  ];

  /// Projects a roster entry's `education`/`job` strings into one
  /// [PersonHistoryEntry] each (T7.3's Education/Job sections are lists, not
  /// single fields) — a no-op past the first run, same idempotent-by-fixed-id
  /// trick as everything else here.
  Future<void> _seedHistoryFromSpec(
    String personId, {
    required String education,
    required String job,
  }) async {
    if (education.isNotEmpty &&
        (await personStore.historyFor(
          personId,
          HistoryCategory.education,
        )).isEmpty) {
      await personStore.addHistoryEntry(
        PersonHistoryEntry(
          id: '$personId-history-education',
          personId: personId,
          category: HistoryCategory.education,
          title: education,
        ),
      );
    }
    if (job.isNotEmpty &&
        (await personStore.historyFor(personId, HistoryCategory.job)).isEmpty) {
      await personStore.addHistoryEntry(
        PersonHistoryEntry(
          id: '$personId-history-job',
          personId: personId,
          category: HistoryCategory.job,
          title: job,
        ),
      );
    }
  }

  /// Three named [Person] profiles (T7) with bios, tagged photos, a
  /// friend + a family relationship between them, and one location history
  /// (T7.7) — enough to see People, the profile lock, and the relationship
  /// graph all populated without an OpenAI key. Idempotent by fixed id, same
  /// "Reset Demo Data" trick as the albums above.
  Future<void> _seedDemoPeople(List<AssetRecord> added) async {
    for (final spec in _demoPeople) {
      final person = await personStore.create(
        name: spec.name,
        id: spec.id,
        isDemo: true,
      );
      if (person.avatarLocalId == null) {
        await personStore.update(
          person.copyWith(
            avatarLocalId: added[spec.avatarIndex].localId,
            bio: spec.bio,
          ),
        );
      }
      final (start, end) = spec.photoRange;
      await personStore.addAssets(
        spec.id,
        added.sublist(start, end).map((r) => r.localId),
      );
      await _seedHistoryFromSpec(
        spec.id,
        education: spec.education,
        job: spec.job,
      );
    }
    await personStore.addRelationship(
      'demo-person-mia',
      'demo-person-daniel',
      RelationshipType.friend,
    );
    await personStore.addRelationship(
      'demo-person-mia',
      'demo-person-grandma-lily',
      RelationshipType.family,
    );

    if ((await personStore.locationsFor('demo-person-grandma-lily')).isEmpty) {
      await personStore.addLocation(
        PersonLocation(
          id: 'demo-loc-lily-origin',
          personId: 'demo-person-grandma-lily',
          kind: LocationKind.origin,
          place: 'Guangzhou, China',
          since: DateTime(1950),
        ),
      );
      await personStore.addLocation(
        PersonLocation(
          id: 'demo-loc-lily-relocation',
          personId: 'demo-person-grandma-lily',
          kind: LocationKind.relocation,
          place: 'Vancouver, Canada',
          since: DateTime(1985),
        ),
      );
    }
    if ((await personStore.locationsFor('demo-person-mia')).isEmpty) {
      await personStore.addLocation(
        PersonLocation(
          id: 'demo-loc-mia-origin',
          personId: 'demo-person-mia',
          kind: LocationKind.origin,
          place: 'Shanghai, China',
          since: DateTime(1995),
        ),
      );
    }
  }

  /// A second, standalone demo network: one 40-year-old man (Marcus) with
  /// every `RelationshipType` represented at least once — family, spouse,
  /// parent, child, sibling, friend, colleague, schoolmate, other — plus
  /// two organizations each for colleague/schoolmate (so the searchable
  /// organization picker has real variety) and a 4-stop Places Lived
  /// history. Only the closest few (Marcus/Elena/Chris/the kids) get an
  /// avatar + tagged photos; everyone else is name-only or has just the one
  /// field (job/education) that reinforces their organization — realistic,
  /// since nobody has tagged photos of every coworker or classmate.
  static const _marcusNetworkPeople = [
    (
      id: 'demo-person-marcus',
      name: 'Marcus Bennett',
      avatarIndex: 12,
      photoRange: (12, 14),
      education: 'Ohio State University',
      job: 'Engineering Manager',
      bio: 'Dad of two, weekend runner, still recovering from his last marathon.',
    ),
    (
      id: 'demo-person-elena',
      name: 'Elena Bennett',
      avatarIndex: 16,
      photoRange: (16, 18),
      education: 'University of Chicago',
      job: 'Marketing Director',
      bio: "Marcus's wife — runs the household calendar like a project plan.",
    ),
    (
      id: 'demo-person-chris',
      name: 'Chris Bennett',
      avatarIndex: 22,
      photoRange: (22, 23),
      education: 'Kent State University',
      job: 'High School Teacher',
      bio: "Marcus's younger brother, still back in Cleveland.",
    ),
    (
      id: 'demo-person-lily-bennett',
      name: 'Lily Bennett',
      avatarIndex: 19,
      photoRange: (19, 20),
      education: 'Eastside Elementary, 5th grade',
      job: '',
      bio: '',
    ),
    (
      id: 'demo-person-owen',
      name: 'Owen Bennett',
      avatarIndex: 20,
      photoRange: (20, 21),
      education: 'Eastside Elementary, 2nd grade',
      job: '',
      bio: '',
    ),
    (
      id: 'demo-person-robert',
      name: 'Robert Bennett',
      avatarIndex: null,
      photoRange: null,
      education: '',
      job: 'Retired factory foreman',
      bio: '',
    ),
    (
      id: 'demo-person-susan',
      name: 'Susan Bennett',
      avatarIndex: null,
      photoRange: null,
      education: '',
      job: 'Retired nurse',
      bio: '',
    ),
    (
      id: 'demo-person-rose',
      name: 'Rose Bennett',
      avatarIndex: null,
      photoRange: null,
      education: '',
      job: '',
      bio: "Marcus's grandmother.",
    ),
    (
      id: 'demo-person-diane',
      name: 'Diane Kowalski',
      avatarIndex: null,
      photoRange: null,
      education: '',
      job: '',
      bio: "Elena's mother.",
    ),
    (
      id: 'demo-person-jake',
      name: 'Jake Turner',
      avatarIndex: null,
      photoRange: null,
      education: '',
      job: '',
      bio: 'Childhood best friend from Cleveland.',
    ),
    (
      id: 'demo-person-priya',
      name: 'Priya Anand',
      avatarIndex: null,
      photoRange: null,
      education: 'Ohio State University',
      job: '',
      bio: 'College friend.',
    ),
    (
      id: 'demo-person-sarah-kim',
      name: 'Sarah Kim',
      avatarIndex: null,
      photoRange: null,
      education: '',
      job: 'Product Manager at Nimbus Systems',
      bio: '',
    ),
    (
      id: 'demo-person-tom',
      name: 'Tom Delgado',
      avatarIndex: null,
      photoRange: null,
      education: '',
      job: 'Former colleague at BrightPath Retail',
      bio: '',
    ),
    (
      id: 'demo-person-ben',
      name: 'Ben Osei',
      avatarIndex: null,
      photoRange: null,
      education: 'Ohio State University',
      job: '',
      bio: '',
    ),
    (
      id: 'demo-person-nora',
      name: 'Nora Fitch',
      avatarIndex: null,
      photoRange: null,
      education: 'Cleveland Heights High School',
      job: '',
      bio: '',
    ),
    (
      id: 'demo-person-dave',
      name: 'Dave Alvarez',
      avatarIndex: null,
      photoRange: null,
      education: '',
      job: '',
      bio: 'Running buddy from the Seattle Road Runners club.',
    ),
  ];

  /// Marcus's own role in each link (see `PersonStore.addRelationship`'s
  /// doc: the first id passed plays the given `type`) — e.g. `child` here
  /// means Marcus is a child of Robert/Susan, `parent` means Marcus is a
  /// parent of Lily/Owen.
  static const _marcusRelationships = [
    (
      id: 'demo-person-elena',
      type: RelationshipType.spouse,
      organization: null,
    ),
    (
      id: 'demo-person-robert',
      type: RelationshipType.child,
      organization: null,
    ),
    (id: 'demo-person-susan', type: RelationshipType.child, organization: null),
    (
      id: 'demo-person-chris',
      type: RelationshipType.sibling,
      organization: null,
    ),
    (
      id: 'demo-person-lily-bennett',
      type: RelationshipType.parent,
      organization: null,
    ),
    (id: 'demo-person-owen', type: RelationshipType.parent, organization: null),
    (id: 'demo-person-rose', type: RelationshipType.family, organization: null),
    (
      id: 'demo-person-diane',
      type: RelationshipType.family,
      organization: null,
    ),
    (id: 'demo-person-jake', type: RelationshipType.friend, organization: null),
    (
      id: 'demo-person-priya',
      type: RelationshipType.friend,
      organization: null,
    ),
    (
      id: 'demo-person-sarah-kim',
      type: RelationshipType.colleague,
      organization: 'Nimbus Systems',
    ),
    (
      id: 'demo-person-tom',
      type: RelationshipType.colleague,
      organization: 'BrightPath Retail',
    ),
    (
      id: 'demo-person-ben',
      type: RelationshipType.schoolmate,
      organization: 'Ohio State University',
    ),
    (
      id: 'demo-person-nora',
      type: RelationshipType.schoolmate,
      organization: 'Cleveland Heights High School',
    ),
    (
      id: 'demo-person-dave',
      type: RelationshipType.other,
      organization: 'Seattle Road Runners',
    ),
  ];

  static const _marcusLocations = [
    (
      id: 'demo-loc-marcus-origin',
      kind: LocationKind.origin,
      place: 'Cleveland, OH',
      since: 1986,
    ),
    (
      id: 'demo-loc-marcus-college',
      kind: LocationKind.relocation,
      place: 'Columbus, OH',
      since: 2004,
    ),
    (
      id: 'demo-loc-marcus-first-job',
      kind: LocationKind.relocation,
      place: 'Chicago, IL',
      since: 2009,
    ),
    (
      id: 'demo-loc-marcus-current',
      kind: LocationKind.relocation,
      place: 'Seattle, WA',
      since: 2015,
    ),
  ];

  Future<void> _seedMarcusNetwork(List<AssetRecord> added) async {
    for (final spec in _marcusNetworkPeople) {
      final person = await personStore.create(
        name: spec.name,
        id: spec.id,
        isDemo: true,
      );
      final avatarIndex = spec.avatarIndex;
      if (avatarIndex != null) {
        if (person.avatarLocalId == null) {
          await personStore.update(
            person.copyWith(
              avatarLocalId: added[avatarIndex].localId,
              bio: spec.bio,
            ),
          );
        }
        final (start, end) = spec.photoRange!;
        await personStore.addAssets(
          spec.id,
          added.sublist(start, end).map((r) => r.localId),
        );
      } else if (person.bio.isEmpty) {
        await personStore.update(person.copyWith(bio: spec.bio));
      }
      await _seedHistoryFromSpec(
        spec.id,
        education: spec.education,
        job: spec.job,
      );
    }
    for (final rel in _marcusRelationships) {
      await personStore.addRelationship(
        'demo-person-marcus',
        rel.id,
        rel.type,
        organization: rel.organization,
      );
    }
    if ((await personStore.locationsFor('demo-person-marcus')).isEmpty) {
      for (final loc in _marcusLocations) {
        await personStore.addLocation(
          PersonLocation(
            id: loc.id,
            personId: 'demo-person-marcus',
            kind: loc.kind,
            place: loc.place,
            since: DateTime(loc.since),
          ),
        );
      }
    }
  }
}

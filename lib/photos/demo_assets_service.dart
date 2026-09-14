import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import '../storage/private_album_store.dart';
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
    PrivateAlbumStore? privateAlbumStore,
    PersonStore? personStore,
    Future<Directory> Function()? targetDirectory,
  }) : albumStore = albumStore ?? AlbumStore(),
       privateAlbumStore = privateAlbumStore ?? PrivateAlbumStore(),
       personStore = personStore ?? PersonStore(),
       _targetDirectory = targetDirectory ?? getTemporaryDirectory;

  final ManualAddService manualAddService;
  final AlbumStore albumStore;
  final PrivateAlbumStore privateAlbumStore;
  final PersonStore personStore;
  final Future<Directory> Function() _targetDirectory;

  /// Demo Private Album passcode — documented here (not shown in-app; that
  /// would defeat the point) so "Reset Demo Data" has something to show off
  /// the Hidden/Private Albums feature with. Try entering `1234` on the
  /// Utilities "Hidden" row.
  static const demoPrivateAlbumPasscode = '1234';

  static final assetPaths = [
    for (var i = 1; i <= 50; i++) 'assets/demo/demo_photo_${i.toString().padLeft(2, '0')}.jpg',
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
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      added.add(await manualAddService.enqueueFile(file.path, createdAt: demoDays[i % demoDays.length]));
    }
    await _seedDemoAlbums(added);
    await _seedDemoPrivateAlbum(added);
    await _seedDemoPeople(added);
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
    DateTime(now.year - 1, now.month, now.day).subtract(const Duration(days: 60)),
    DateTime(now.year - 2, now.month, now.day),
  ];

  Future<void> _seedDemoAlbums(List<AssetRecord> added) async {
    for (final spec in _demoAlbums) {
      final (start, end) = spec.range;
      await albumStore.upsert(id: spec.id, name: spec.name, isDemo: true);
      await albumStore.addAssets(spec.id, added.sublist(start, end).map((r) => r.localId));
    }
  }

  /// A ready-to-open Private Album (T6) at [demoPrivateAlbumPasscode] — a
  /// few nature photos *moved* in (hidden from the main library/Nature
  /// album, same as a real move) and one city photo *copied* in (stays
  /// visible everywhere else too), so both actions are visible on first
  /// look. Re-running after the album's been deleted recreates it, same
  /// "Reset Demo Data" trick as the albums above.
  Future<void> _seedDemoPrivateAlbum(List<AssetRecord> added) async {
    final album = await privateAlbumStore.ensure(demoPrivateAlbumPasscode);
    final moved = added.sublist(5, 8).map((r) => r.localId).toList();
    final copied = [added[30].localId];
    await privateAlbumStore.addAssets(album.id, moved, moved: true);
    for (final id in moved) {
      await manualAddService.store.setHidden(id, true);
    }
    await privateAlbumStore.addAssets(album.id, copied, moved: false);
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

  /// Three named [Person] profiles (T7) with bios, tagged photos, a
  /// friend + a family relationship between them, and one location history
  /// (T7.7) — enough to see People, the profile lock, and the relationship
  /// graph all populated without an OpenAI key. Idempotent by fixed id, same
  /// "Reset Demo Data" trick as the albums above.
  Future<void> _seedDemoPeople(List<AssetRecord> added) async {
    for (final spec in _demoPeople) {
      final person = await personStore.create(name: spec.name, id: spec.id, isDemo: true);
      if (person.avatarLocalId == null) {
        await personStore.update(
          person.copyWith(avatarLocalId: added[spec.avatarIndex].localId, education: spec.education, job: spec.job, bio: spec.bio),
        );
      }
      final (start, end) = spec.photoRange;
      await personStore.addAssets(spec.id, added.sublist(start, end).map((r) => r.localId));
    }
    await personStore.addRelationship('demo-person-mia', 'demo-person-daniel', RelationshipType.friend);
    await personStore.addRelationship('demo-person-mia', 'demo-person-grandma-lily', RelationshipType.family);

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
}

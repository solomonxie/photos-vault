import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../storage/album_store.dart';
import '../storage/asset_record.dart';
import 'manual_add.dart';

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
    Future<Directory> Function()? targetDirectory,
  }) : albumStore = albumStore ?? AlbumStore(),
       _targetDirectory = targetDirectory ?? getTemporaryDirectory;

  final ManualAddService manualAddService;
  final AlbumStore albumStore;
  final Future<Directory> Function() _targetDirectory;

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
    final now = DateTime.now();
    final added = <AssetRecord>[];
    for (var i = 0; i < assetPaths.length; i++) {
      final assetPath = assetPaths[i];
      final data = await rootBundle.load(assetPath);
      final fileName = assetPath.split('/').last;
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      added.add(await manualAddService.enqueueFile(file.path, createdAt: _staggeredCreatedAt(now, i)));
    }
    await _seedDemoAlbums(added);
    return added;
  }

  /// Backdates demo asset [index] by a growing number of days, so the
  /// day-grouped Library grid shows several distinct days/years right out
  /// of the box instead of one giant "Today" pile — only applied on first
  /// insert (see `AssetRecordStore.upsert`), so a reset doesn't shuffle
  /// dates on items already present.
  static DateTime _staggeredCreatedAt(DateTime now, int index) => now.subtract(Duration(days: index * 26));

  Future<void> _seedDemoAlbums(List<AssetRecord> added) async {
    for (final spec in _demoAlbums) {
      final (start, end) = spec.range;
      await albumStore.upsert(id: spec.id, name: spec.name, isDemo: true);
      await albumStore.addAssets(spec.id, added.sublist(start, end).map((r) => r.localId));
    }
  }
}

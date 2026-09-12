import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../storage/asset_record.dart';
import 'manual_add.dart';

/// Ships a handful of tiny bundled photos/videos so the app is immediately
/// tryable — pick "Try with Demo Photos" and there's something to back up
/// without first hunting for a file or setting up S3.
///
/// Enqueueing goes through [ManualAddService], which keys `localId` off the
/// file's content hash — re-adding an already-present demo item is a no-op,
/// and re-adding one the user deleted (Settings' "Reset Demo Data") brings
/// it right back. Copies land in application-support storage, not the
/// system temp dir — the OS can clear temp between launches, which would
/// leave a saved record pointing at a file that's silently gone.
class DemoAssetsService {
  DemoAssetsService({required this.manualAddService, Future<Directory> Function()? targetDirectory})
    : _targetDirectory = targetDirectory ?? getApplicationSupportDirectory;

  final ManualAddService manualAddService;
  final Future<Directory> Function() _targetDirectory;

  static final assetPaths = [
    for (var i = 1; i <= 50; i++) 'assets/demo/demo_photo_${i.toString().padLeft(2, '0')}.jpg',
    'assets/demo/demo_video_1.mp4',
  ];

  Future<List<AssetRecord>> addAll() async {
    final dir = await _targetDirectory();
    final added = <AssetRecord>[];
    for (final assetPath in assetPaths) {
      final data = await rootBundle.load(assetPath);
      final fileName = assetPath.split('/').last;
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      added.add(await manualAddService.enqueueFile(file.path));
    }
    return added;
  }
}

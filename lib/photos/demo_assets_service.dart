import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../storage/asset_record.dart';
import 'manual_add.dart';

/// Ships a handful of tiny bundled photos/videos so the app is immediately
/// tryable — pick "Try with Demo Photos" and there's something to back up
/// without first hunting for a file or setting up S3.
///
/// Enqueueing goes through [ManualAddService], which keys `localId` off the
/// file's content hash — re-adding an already-present demo item is a no-op,
/// and re-adding one the user deleted (Settings' "Reset Demo Data") brings
/// it right back.
class DemoAssetsService {
  DemoAssetsService({required this.manualAddService});

  final ManualAddService manualAddService;

  static const assetPaths = [
    'assets/demo/demo_photo_1.jpg',
    'assets/demo/demo_photo_2.jpg',
    'assets/demo/demo_video_1.mp4',
  ];

  Future<List<AssetRecord>> addAll() async {
    final added = <AssetRecord>[];
    for (final assetPath in assetPaths) {
      final data = await rootBundle.load(assetPath);
      final fileName = assetPath.split('/').last;
      final file = File('${Directory.systemTemp.path}/$fileName');
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      added.add(await manualAddService.enqueueFile(file.path));
    }
    return added;
  }
}
